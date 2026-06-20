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

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/movies-h265-vaapi-$(date +%Y%m%d-%H%M%S).log"
FAILED_LIST="$LOG_DIR/failed-$(date +%Y%m%d-%H%M%S).txt"
SKIPPED_LIST="$LOG_DIR/skipped-$(date +%Y%m%d-%H%M%S).txt"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

probe_field() {
  local file="$1"
  local stream_spec="$2"
  local field="$3"
  ffprobe -v error -select_streams "$stream_spec" \
    -show_entries "stream=$field" -of default=nw=1:nk=1 "$file" 2>/dev/null | head -n 1
}

duration_seconds() {
  local file="$1"
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" 2>/dev/null | head -n 1
}

audio_count() {
  local file="$1"
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$file" 2>/dev/null | wc -l
}

needs_ac3_fallback() {
  local file="$1"
  local first_audio
  first_audio="$(probe_field "$file" a:0 codec_name)"
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
    tolerance = (a * 0.01);
    if (tolerance < 5) tolerance = 5;
    exit(d <= tolerance ? 0 : 1);
  }'
}

verify_output() {
  local src="$1"
  local out="$2"
  local src_dur out_dur out_codec out_format

  [[ -s "$out" ]] || return 1
  out_codec="$(probe_field "$out" v:0 codec_name)"
  [[ "$out_codec" == "hevc" ]] || return 1

  out_format="$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$out" 2>/dev/null | head -n 1)"
  [[ "$out_format" == *matroska* ]] || return 1

  src_dur="$(duration_seconds "$src")"
  out_dur="$(duration_seconds "$out")"
  is_close_duration "$src_dur" "$out_dur"
}

transcode_one() {
  local src="$1"
  local codec pix_fmt profile vf base dir stem final tmp ext audio_tracks fallback_index subtitle_codec

  codec="$(probe_field "$src" v:0 codec_name)"
  if [[ -z "$codec" ]]; then
    log "SKIP no-probe: $src"
    printf '%s\n' "$src" >> "$SKIPPED_LIST"
    return 0
  fi

  ext="${src##*.}"
  ext="${ext,,}"
  case "$ext" in
    mp4|m4v|mov)
      subtitle_codec="srt"
      ;;
    *)
      subtitle_codec="copy"
      ;;
  esac
  if [[ "$codec" == "hevc" && "$ext" == "mkv" ]] && ! needs_ac3_fallback "$src"; then
    log "SKIP already-hevc: $src"
    printf '%s\n' "$src" >> "$SKIPPED_LIST"
    return 0
  fi

  dir="$(dirname "$src")"
  base="$(basename "$src")"
  stem="${base%.*}"
  final="$dir/$stem.h265.mkv"
  tmp="$dir/.$stem.h265.tmp.mkv"

  if [[ -e "$final" ]]; then
    log "SKIP output-exists: $final"
    printf '%s\n' "$src" >> "$SKIPPED_LIST"
    return 0
  fi

  pix_fmt="$(probe_field "$src" v:0 pix_fmt)"
  if [[ "$pix_fmt" == *10* || "$pix_fmt" == *12* ]]; then
    profile="main10"
    vf="format=p010le,hwupload"
  else
    profile="main"
    vf="format=nv12,hwupload"
  fi

  log "START $src"
  log "SOURCE codec=$codec pix_fmt=$pix_fmt output=$final"
  audio_tracks="$(audio_count "$src")"
  fallback_index="$audio_tracks"
  if [[ "$audio_tracks" -gt 0 ]] && needs_ac3_fallback "$src"; then
    log "AUDIO adding AC-3 5.1 fallback for Apple TV compatibility"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would transcode: $src"
    return 0
  fi

  rm -f "$tmp"
  if [[ "$codec" == "hevc" ]]; then
    log "REMUX already-hevc-to-mkv: $src"
    if [[ "$audio_tracks" -gt 0 ]] && needs_ac3_fallback "$src"; then
      ffmpeg -hide_banner -nostdin -y \
        -i "$src" \
        -map 0:v:0 -map 0:a? -map 0:a:0 -map 0:s? -map 0:t? \
        -map_metadata 0 -map_chapters 0 \
        -c copy -c:s "$subtitle_codec" \
        -c:a:"$fallback_index" ac3 -b:a:"$fallback_index" 640k -ac:a:"$fallback_index" 6 \
        -metadata:s:a:"$fallback_index" title="Apple TV AC-3 fallback" \
        "$tmp" >> "$LOG_FILE" 2>&1
    else
      ffmpeg -hide_banner -nostdin -y \
        -i "$src" \
        -map 0:v:0 -map 0:a? -map 0:s? -map 0:t? \
        -map_metadata 0 -map_chapters 0 \
        -c copy -c:s "$subtitle_codec" \
        "$tmp" >> "$LOG_FILE" 2>&1
    fi
  else
    if [[ "$audio_tracks" -gt 0 ]] && needs_ac3_fallback "$src"; then
      ffmpeg -hide_banner -nostdin -y \
        -vaapi_device "$GPU_DEVICE" \
        -i "$src" \
        -map 0:v:0 -map 0:a? -map 0:a:0 -map 0:s? -map 0:t? \
        -map_metadata 0 -map_chapters 0 \
        -vf "$vf" \
        -c:v hevc_vaapi -profile:v "$profile" -rc_mode CQP -qp "$QUALITY_QP" \
        -c:a copy -c:s "$subtitle_codec" -c:t copy \
        -c:a:"$fallback_index" ac3 -b:a:"$fallback_index" 640k -ac:a:"$fallback_index" 6 \
        -metadata:s:a:"$fallback_index" title="Apple TV AC-3 fallback" \
        "$tmp" >> "$LOG_FILE" 2>&1
    else
      ffmpeg -hide_banner -nostdin -y \
        -vaapi_device "$GPU_DEVICE" \
        -i "$src" \
        -map 0:v:0 -map 0:a? -map 0:s? -map 0:t? \
        -map_metadata 0 -map_chapters 0 \
        -vf "$vf" \
        -c:v hevc_vaapi -profile:v "$profile" -rc_mode CQP -qp "$QUALITY_QP" \
        -c:a copy -c:s "$subtitle_codec" -c:t copy \
        "$tmp" >> "$LOG_FILE" 2>&1
    fi
  fi

  if [[ "$?" -eq 0 ]]; then
    if verify_output "$src" "$tmp"; then
      mv -f "$tmp" "$final"
      rm -f "$src"
      log "DONE verified-and-deleted-original: $final"
      return 0
    fi
    log "FAIL verification: $src"
  else
    log "FAIL ffmpeg: $src"
  fi

  rm -f "$tmp"
  printf '%s\n' "$src" >> "$FAILED_LIST"
  return 0
}

main() {
  log "Library: $LIBRARY"
  log "GPU device: $GPU_DEVICE"
  log "Quality QP: $QUALITY_QP"
  log "Dry run: $DRY_RUN"
  log "Log file: $LOG_FILE"

  if [[ ! -d "$LIBRARY" ]]; then
    log "ERROR library not found: $LIBRARY"
    exit 1
  fi
  if [[ ! -e "$GPU_DEVICE" ]]; then
    log "ERROR GPU device not found: $GPU_DEVICE"
    exit 1
  fi

  find "$LIBRARY" \( -path "$LIBRARY/output" -o -path "$LIBRARY/output/*" -o -name '.*' \) -prune -o \
  -type f ! -name '.*' \( \
    -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o \
    -iname '*.m2ts' -o -iname '*.ts' -o -iname '*.mov' -o -iname '*.avi' \
  \) -print0 | while IFS= read -r -d '' src; do
    case "$src" in
      *.h265.mkv|*.H265.MKV|*.hevc.mkv|*.HEVC.MKV|*.tmp.mkv) continue ;;
    esac
    transcode_one "$src"
  done

  log "Complete. Failed list: $FAILED_LIST"
  log "Complete. Skipped list: $SKIPPED_LIST"
}

main "$@"
