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
LOG_DIR="${LOG_DIR:-$REPO_DIR/transcode-logs}"
DRY_RUN="${DRY_RUN:-1}"
SKIP_ACTIVE_RETRY_DIRS="${SKIP_ACTIVE_RETRY_DIRS:-0}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/filename-standardize-$(date +%Y%m%d-%H%M%S).log"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

is_active_retry_dir() {
  [[ -n "${ACTIVE_RETRY_DIRS:-}" ]] || return 1
  [[ ":$ACTIVE_RETRY_DIRS:" == *":$1:"* ]]
}

target_for() {
  local src="$1"
  local dir title base lower target_ext
  dir="$(dirname "$src")"
  title="$(basename "$dir")"
  base="$(basename "$src")"
  lower="${base,,}"

  case "$lower" in
    *.h265.mkv|*.hevc.mkv)
      target_ext="h265.mkv"
      ;;
    *.mkv)
      target_ext="mkv"
      ;;
    *.mp4)
      target_ext="mp4"
      ;;
    *.m4v)
      target_ext="m4v"
      ;;
    *.mov)
      target_ext="mov"
      ;;
    *.avi)
      target_ext="avi"
      ;;
    *.m2ts)
      target_ext="m2ts"
      ;;
    *.ts)
      target_ext="ts"
      ;;
    *.iso)
      target_ext="iso"
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s/%s.%s\n' "$dir" "$title" "$target_ext"
}

main() {
  local src target dir
  log "Library: $LIBRARY"
  log "Dry run: $DRY_RUN"
  log "Log file: $LOG_FILE"

  find "$LIBRARY" \( -path "$LIBRARY/output" -o -path "$LIBRARY/output/*" -o -name '.*' \) -prune -o \
    -type f ! -name '.*' \( \
      -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o \
      -iname '*.m2ts' -o -iname '*.ts' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.iso' \
    \) -print0 |
  while IFS= read -r -d '' src; do
    dir="$(dirname "$src")"
    if [[ "$SKIP_ACTIVE_RETRY_DIRS" == "1" ]] && is_active_retry_dir "$dir"; then
      log "SKIP active-retry-dir: $src"
      continue
    fi

    target="$(target_for "$src")" || {
      log "SKIP unknown-extension: $src"
      continue
    }

    if [[ "$src" == "$target" ]]; then
      log "OK already-standard: $src"
      continue
    fi

    if [[ -e "$target" ]]; then
      log "SKIP target-exists: $src -> $target"
      continue
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY-RUN rename: $src -> $target"
    else
      mv -- "$src" "$target"
      log "RENAMED: $src -> $target"
    fi
  done
}

main "$@"
