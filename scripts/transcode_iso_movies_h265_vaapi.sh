#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${MOVIE_TRANSCODE_CONFIG:-$REPO_DIR/movie-transcode.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

LIBRARY="${LIBRARY:-${MOVIE_LIBRARY:-/mnt/media-stack-library/movies}}"
GPU_DEVICE="${GPU_DEVICE:-/dev/dri/renderD129}"
LOG_DIR="${LOG_DIR:-$REPO_DIR/transcode-logs}"
QUALITY_QP="${QUALITY_QP:-24}"
DRY_RUN="${DRY_RUN:-0}"
MIN_MAIN_SECONDS="${MIN_MAIN_SECONDS:-3600}"
MOUNT_ROOT="${MOUNT_ROOT:-/tmp/iso-transcode-mounts}"

mkdir -p "$LOG_DIR" "$MOUNT_ROOT"
LOG_FILE="$LOG_DIR/iso-h265-vaapi-$(date +%Y%m%d-%H%M%S).log"
FAILED_LIST="$LOG_DIR/iso-failed-$(date +%Y%m%d-%H%M%S).txt"
SKIPPED_LIST="$LOG_DIR/iso-skipped-$(date +%Y%m%d-%H%M%S).txt"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

duration_seconds() {
  local file="$1"
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" 2>/dev/null | head -n 1
}

probe_stream_codec() {
  local file="$1"
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$file" 2>/dev/null | head -n 1
}

audio_count() {
  local file="$1"
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$file" 2>/dev/null | wc -l
}

needs_ac3_fallback() {
  local file="$1"
  local first_audio
  first_audio="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$file" 2>/dev/null | head -n 1)"
  case "$first_audio" in
    ""|aac|ac3|eac3|alac) return 1 ;;
    *) return 0 ;;
  esac
}

concat_audio_count() {
  local concat_file="$1"
  ffprobe -v error -f concat -safe 0 -i "$concat_file" -select_streams a -show_entries stream=index -of csv=p=0 2>/dev/null | wc -l
}

concat_needs_ac3_fallback() {
  local concat_file="$1"
  local first_audio
  first_audio="$(ffprobe -v error -f concat -safe 0 -i "$concat_file" -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 2>/dev/null | head -n 1)"
  case "$first_audio" in
    ""|aac|ac3|eac3|alac) return 1 ;;
    *) return 0 ;;
  esac
}

is_close_duration() {
  local src_dur="$1"
  local out_dur="$2"
  awk -v a="$src_dur" -v b="$out_dur" 'BEGIN {
    if (a <= 0 || b <= 0) exit 1;
    d = a - b;
    if (d < 0) d = -d;
    tolerance = (a * 0.02);
    if (tolerance < 10) tolerance = 10;
    exit(d <= tolerance ? 0 : 1);
  }'
}

verify_output() {
  local src_duration="$1"
  local out="$2"
  local out_codec out_format out_dur

  [[ -s "$out" ]] || return 1
  out_codec="$(probe_stream_codec "$out")"
  [[ "$out_codec" == "hevc" ]] || return 1

  out_format="$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$out" 2>/dev/null | head -n 1)"
  [[ "$out_format" == *matroska* ]] || return 1

  out_dur="$(duration_seconds "$out")"
  is_close_duration "$src_duration" "$out_dur"
}

largest_file_matching() {
  local root="$1"
  local pattern="$2"
  find "$root" -type f -iname "$pattern" -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n 1 | cut -f2-
}

dvd_concat_for_main_title() {
  local root="$1"
  local best_group
  best_group="$(
    find "$root" -type f -iregex '.*/VIDEO_TS/VTS_[0-9][0-9]_[1-9]\.VOB' -printf '%f\t%s\n' 2>/dev/null |
      awk -F '\t' '{ group=substr($1, 1, 6); sum[group]+=$2 } END { for (g in sum) print sum[g] "\t" g }' |
      sort -nr | head -n 1 | cut -f2
  )"

  [[ -n "$best_group" ]] || return 1
  find "$root" -type f -iregex ".*/VIDEO_TS/${best_group}_[1-9]\\.VOB" -print 2>/dev/null | sort
}

write_concat_file() {
  local concat_file="$1"
  shift
  : > "$concat_file"
  for file in "$@"; do
    printf "file '%s'\n" "${file//\'/\'\\\'\'}" >> "$concat_file"
  done
}

transcode_iso() {
  local iso="$1"
  local mount_dir base dir stem final tmp main_file main_duration codec concat_file audio_tracks fallback_index
  local -a dvd_files

  dir="$(dirname "$iso")"
  base="$(basename "$iso")"
  stem="${base%.*}"
  final="$dir/$stem.h265.mkv"
  tmp="$dir/.$stem.h265.tmp.mkv"
  mount_dir="$MOUNT_ROOT/iso-$$-$(date +%s%N)"
  concat_file="$mount_dir/dvd-concat.txt"

  if [[ -e "$final" ]]; then
    log "SKIP output-exists: $final"
    printf '%s\n' "$iso" >> "$SKIPPED_LIST"
    return 0
  fi

  mkdir -p "$mount_dir"
  if ! mount -o loop,ro "$iso" "$mount_dir" >> "$LOG_FILE" 2>&1; then
    log "FAIL mount: $iso"
    rmdir "$mount_dir" 2>/dev/null
    printf '%s\n' "$iso" >> "$FAILED_LIST"
    return 0
  fi

  main_file="$(largest_file_matching "$mount_dir" '*.m2ts')"
  if [[ -n "$main_file" ]]; then
    main_duration="$(duration_seconds "$main_file")"
    codec="$(probe_stream_codec "$main_file")"
    audio_tracks="$(audio_count "$main_file")"
    fallback_index="$audio_tracks"
    log "ISO blu-ray candidate: $iso"
    log "SOURCE main=$main_file codec=$codec duration=$main_duration output=$final"
    if [[ "$audio_tracks" -gt 0 ]] && needs_ac3_fallback "$main_file"; then
      log "AUDIO adding AC-3 5.1 fallback for Apple TV compatibility"
    fi
    if ! awk -v d="$main_duration" -v min="$MIN_MAIN_SECONDS" 'BEGIN { exit(d >= min ? 0 : 1) }'; then
      log "SKIP iso-main-too-short: $iso"
      umount "$mount_dir" >> "$LOG_FILE" 2>&1
      rmdir "$mount_dir" 2>/dev/null
      printf '%s\n' "$iso" >> "$SKIPPED_LIST"
      return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY-RUN would transcode ISO: $iso"
      umount "$mount_dir" >> "$LOG_FILE" 2>&1
      rmdir "$mount_dir" 2>/dev/null
      return 0
    fi

    rm -f "$tmp"
    if [[ "$codec" == "hevc" && "$audio_tracks" -gt 0 ]] && needs_ac3_fallback "$main_file"; then
      ffmpeg -hide_banner -nostdin -y \
          -i "$main_file" \
          -map 0:v:0 -map 0:a? -map 0:a:0 -map 0:s? \
          -c copy \
          -c:a:"$fallback_index" ac3 -b:a:"$fallback_index" 640k -ac:a:"$fallback_index" 6 \
          -metadata:s:a:"$fallback_index" title="Apple TV AC-3 fallback" \
          "$tmp" >> "$LOG_FILE" 2>&1
    elif [[ "$codec" == "hevc" ]]; then
      ffmpeg -hide_banner -nostdin -y \
          -i "$main_file" \
          -map 0:v:0 -map 0:a? -map 0:s? \
          -c copy \
          "$tmp" >> "$LOG_FILE" 2>&1
    elif [[ "$audio_tracks" -gt 0 ]] && needs_ac3_fallback "$main_file"; then
      ffmpeg -hide_banner -nostdin -y \
          -vaapi_device "$GPU_DEVICE" \
          -i "$main_file" \
          -map 0:v:0 -map 0:a? -map 0:a:0 -map 0:s? \
          -vf 'format=nv12,hwupload' \
          -c:v hevc_vaapi -profile:v main -rc_mode CQP -qp "$QUALITY_QP" \
          -c:a copy -c:s copy \
          -c:a:"$fallback_index" ac3 -b:a:"$fallback_index" 640k -ac:a:"$fallback_index" 6 \
          -metadata:s:a:"$fallback_index" title="Apple TV AC-3 fallback" \
          "$tmp" >> "$LOG_FILE" 2>&1
    else
      ffmpeg -hide_banner -nostdin -y \
          -vaapi_device "$GPU_DEVICE" \
          -i "$main_file" \
          -map 0:v:0 -map 0:a? -map 0:s? \
          -vf 'format=nv12,hwupload' \
          -c:v hevc_vaapi -profile:v main -rc_mode CQP -qp "$QUALITY_QP" \
          -c:a copy -c:s copy \
          "$tmp" >> "$LOG_FILE" 2>&1
    fi

    if [[ "$?" -eq 0 ]] &&
        verify_output "$main_duration" "$tmp"; then
      mv -f "$tmp" "$final"
      umount "$mount_dir" >> "$LOG_FILE" 2>&1
      rmdir "$mount_dir" 2>/dev/null
      rm -f "$iso"
      log "DONE iso-verified-and-deleted-original: $final"
      return 0
    fi
  else
    mapfile -t dvd_files < <(dvd_concat_for_main_title "$mount_dir")
    if [[ "${#dvd_files[@]}" -gt 0 ]]; then
      write_concat_file "$concat_file" "${dvd_files[@]}"
      main_duration="$(ffprobe -v error -f concat -safe 0 -i "$concat_file" -show_entries format=duration -of default=nw=1:nk=1 2>/dev/null | head -n 1)"
      codec="$(ffprobe -v error -f concat -safe 0 -i "$concat_file" -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 2>/dev/null | head -n 1)"
      audio_tracks="$(concat_audio_count "$concat_file")"
      fallback_index="$audio_tracks"
      log "ISO dvd candidate: $iso"
      log "SOURCE files=${#dvd_files[@]} codec=$codec duration=$main_duration output=$final"
      if [[ "$audio_tracks" -gt 0 ]] && concat_needs_ac3_fallback "$concat_file"; then
        log "AUDIO adding AC-3 5.1 fallback for Apple TV compatibility"
      fi
      if ! awk -v d="$main_duration" -v min="$MIN_MAIN_SECONDS" 'BEGIN { exit(d >= min ? 0 : 1) }'; then
        log "SKIP iso-main-too-short: $iso"
        umount "$mount_dir" >> "$LOG_FILE" 2>&1
        rmdir "$mount_dir" 2>/dev/null
        printf '%s\n' "$iso" >> "$SKIPPED_LIST"
        return 0
      fi

      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN would transcode ISO: $iso"
        umount "$mount_dir" >> "$LOG_FILE" 2>&1
        rmdir "$mount_dir" 2>/dev/null
        return 0
      fi

      rm -f "$tmp"
      if [[ "$audio_tracks" -gt 0 ]] && concat_needs_ac3_fallback "$concat_file"; then
        ffmpeg -hide_banner -nostdin -y \
          -vaapi_device "$GPU_DEVICE" \
          -f concat -safe 0 -i "$concat_file" \
          -map 0:v:0 -map 0:a? -map 0:a:0 -map 0:s? \
          -vf 'format=nv12,hwupload' \
          -c:v hevc_vaapi -profile:v main -rc_mode CQP -qp "$QUALITY_QP" \
          -c:a copy -c:s copy \
          -c:a:"$fallback_index" ac3 -b:a:"$fallback_index" 640k -ac:a:"$fallback_index" 6 \
          -metadata:s:a:"$fallback_index" title="Apple TV AC-3 fallback" \
          "$tmp" >> "$LOG_FILE" 2>&1
      else
        ffmpeg -hide_banner -nostdin -y \
          -vaapi_device "$GPU_DEVICE" \
          -f concat -safe 0 -i "$concat_file" \
          -map 0:v:0 -map 0:a? -map 0:s? \
          -vf 'format=nv12,hwupload' \
          -c:v hevc_vaapi -profile:v main -rc_mode CQP -qp "$QUALITY_QP" \
          -c:a copy -c:s copy \
          "$tmp" >> "$LOG_FILE" 2>&1
      fi

      if [[ "$?" -eq 0 ]] &&
          verify_output "$main_duration" "$tmp"; then
        mv -f "$tmp" "$final"
        umount "$mount_dir" >> "$LOG_FILE" 2>&1
        rmdir "$mount_dir" 2>/dev/null
        rm -f "$iso"
        log "DONE iso-verified-and-deleted-original: $final"
        return 0
      fi
    else
      log "SKIP no-main-candidate: $iso"
      printf '%s\n' "$iso" >> "$SKIPPED_LIST"
    fi
  fi

  log "FAIL iso-transcode-or-verify: $iso"
  rm -f "$tmp"
  umount "$mount_dir" >> "$LOG_FILE" 2>&1
  rmdir "$mount_dir" 2>/dev/null
  printf '%s\n' "$iso" >> "$FAILED_LIST"
  return 0
}

main() {
  log "Library: $LIBRARY"
  log "GPU device: $GPU_DEVICE"
  log "Quality QP: $QUALITY_QP"
  log "Dry run: $DRY_RUN"
  log "Log file: $LOG_FILE"

  find "$LIBRARY" \( -path "$LIBRARY/output" -o -path "$LIBRARY/output/*" -o -name '.*' \) -prune -o \
  -type f ! -name '.*' -iname '*.iso' -print0 | while IFS= read -r -d '' iso; do
    transcode_iso "$iso"
  done

  log "Complete. Failed list: $FAILED_LIST"
  log "Complete. Skipped list: $SKIPPED_LIST"
}

main "$@"
