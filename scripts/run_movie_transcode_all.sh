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

export MOVIE_LIBRARY="${MOVIE_LIBRARY:-/mnt/media-stack-library/movies}"
export TV_LIBRARY="${TV_LIBRARY:-/mnt/media-stack-library/tv}"
export GPU_DEVICE="${GPU_DEVICE:-/dev/dri/renderD129}"
export QUALITY_QP="${QUALITY_QP:-24}"
export LOG_DIR="${LOG_DIR:-$REPO_DIR/transcode-logs}"

mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/run-all-$(date +%Y%m%d-%H%M%S).log"

{
  printf '[%s] Starting movie video pass\n' "$(date '+%F %T')"
  LIBRARY="$MOVIE_LIBRARY" "$SCRIPT_DIR/transcode_movies_h265_vaapi.sh"
  printf '[%s] Starting TV video pass\n' "$(date '+%F %T')"
  LIBRARY="$TV_LIBRARY" "$SCRIPT_DIR/transcode_movies_h265_vaapi.sh"
  printf '[%s] Starting ISO pass\n' "$(date '+%F %T')"
  LIBRARY="$MOVIE_LIBRARY" "$SCRIPT_DIR/transcode_iso_movies_h265_vaapi.sh"
  printf '[%s] Starting movie filename standardization pass\n' "$(date '+%F %T')"
  LIBRARY="$MOVIE_LIBRARY" DRY_RUN=0 "$SCRIPT_DIR/standardize_movie_filenames.sh"
  printf '[%s] Starting Plex refresh pass\n' "$(date '+%F %T')"
  "$SCRIPT_DIR/refresh_plex_library.sh"
  printf '[%s] All passes complete\n' "$(date '+%F %T')"
} 2>&1 | tee -a "$RUN_LOG"
