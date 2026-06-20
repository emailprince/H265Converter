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
REPORT_DIR="${REPORT_DIR:-$REPO_DIR/transcode-logs}"
mkdir -p "$REPORT_DIR"

REPORT="$REPORT_DIR/duplicate-report-$(date +%Y%m%d-%H%M%S).tsv"
SUMMARY="$REPORT_DIR/duplicate-summary-$(date +%Y%m%d-%H%M%S).txt"

normalize_title() {
  local title="$1"
  printf '%s' "$title" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/\([^)]*\)//g; s/[^a-z0-9]+//g'
}

probe_value() {
  local file="$1"
  local entry="$2"
  ffprobe -v error -show_entries "$entry" -of default=nw=1:nk=1 "$file" 2>/dev/null | head -n 1
}

probe_stream_value() {
  local file="$1"
  local stream="$2"
  local entry="$3"
  ffprobe -v error -select_streams "$stream" -show_entries "stream=$entry" -of default=nw=1:nk=1 "$file" 2>/dev/null | head -n 1
}

printf 'key\tfolder\tfile\text\tsize_bytes\tduration\tvideo_codec\twidth\theight\taudio0_codec\n' > "$REPORT"

find "$LIBRARY" \( -path "$LIBRARY/output" -o -path "$LIBRARY/output/*" -o -name '.*' \) -prune -o \
-mindepth 2 -maxdepth 2 -type f ! -name '.*' \( \
  -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o \
  -iname '*.m2ts' -o -iname '*.ts' -o -iname '*.mov' -o -iname '*.avi' -o \
  -iname '*.iso' \
\) -print0 | while IFS= read -r -d '' file; do
  folder="$(basename "$(dirname "$file")")"
  key="$(normalize_title "$folder")"
  base="$(basename "$file")"
  ext="${base##*.}"
  ext="${ext,,}"
  size="$(stat -c '%s' "$file" 2>/dev/null || printf 0)"

  if [[ "$ext" == "iso" ]]; then
    duration=""
    codec="iso"
    width=""
    height=""
    audio=""
  else
    duration="$(probe_value "$file" format=duration)"
    codec="$(probe_stream_value "$file" v:0 codec_name)"
    width="$(probe_stream_value "$file" v:0 width)"
    height="$(probe_stream_value "$file" v:0 height)"
    audio="$(probe_stream_value "$file" a:0 codec_name)"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$key" "$folder" "$file" "$ext" "$size" "$duration" "$codec" "$width" "$height" "$audio" >> "$REPORT"
done

{
  printf 'Duplicate report: %s\n\n' "$REPORT"
  printf 'Folders with more than one video file:\n'
  awk -F '\t' 'NR > 1 { count[$2]++ } END { for (f in count) if (count[f] > 1) print count[f] "\t" f }' "$REPORT" | sort -nr
  printf '\nNormalized title/year keys spanning multiple folders:\n'
  awk -F '\t' 'NR > 1 { seen[$1 FS $2]=1 } END {
    for (pair in seen) {
      split(pair, p, FS);
      key=p[1]; folder=p[2];
      if (!folders[key]) folders[key]=folder; else if (folders[key] !~ "(^|;)" folder "(;|$)") folders[key]=folders[key] ";" folder;
    }
    for (key in folders) {
      n=split(folders[key], a, ";");
      if (n > 1) print n "\t" key "\t" folders[key];
    }
  }' "$REPORT" | sort -nr
  printf '\nProbe failures or suspicious nonstandard files:\n'
  awk -F '\t' 'NR > 1 && ($7 == "" || $3 ~ /\/\./ || $4 !~ /^(mkv|mp4|m4v|m2ts|ts|mov|avi|iso)$/) { print $2 "\t" $3 "\tcodec=" $7 "\text=" $4 }' "$REPORT"
} | tee "$SUMMARY"

printf '\nWrote summary: %s\n' "$SUMMARY"
