#!/usr/bin/env bash
set -u
set -o pipefail

SESSION="media_h265"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${LOG_DIR:-$REPO_DIR/transcode-logs}"
CRON_LOG="$LOG_DIR/weekly-cron.log"
CONFIG_FILE="${MOVIE_TRANSCODE_CONFIG:-$REPO_DIR/movie-transcode.env}"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

mkdir -p "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$CRON_LOG"
}

if tmux has-session -t "$SESSION" 2>/dev/null; then
  log "Skip: tmux session '$SESSION' is already running"
  exit 0
fi

if pgrep -f 'transcode_.*_h265_vaapi.sh|ffmpeg .*hevc_vaapi' >/dev/null 2>&1; then
  log "Skip: transcode or ffmpeg process is already running"
  exit 0
fi

log "Starting weekly media transcode job"
tmux new-session -d -s "$SESSION" \
  env MOVIE_TRANSCODE_CONFIG="$CONFIG_FILE" "$SCRIPT_DIR/run_movie_transcode_all.sh"
