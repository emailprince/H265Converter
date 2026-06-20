#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${LOG_DIR:-$REPO_DIR/transcode-logs}"
CONFIG_FILE="${PLEX_REFRESH_CONFIG:-$REPO_DIR/plex-refresh.env}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/plex-refresh-$(date +%Y%m%d-%H%M%S).log"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

PLEX_URL="${PLEX_URL:-}"
PLEX_TOKEN="${PLEX_TOKEN:-}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-}"

if [[ -z "$PLEX_URL" || -z "$PLEX_TOKEN" || -z "$PLEX_SECTION_ID" ]]; then
  log "SKIP Plex refresh: set PLEX_URL, PLEX_TOKEN, and PLEX_SECTION_ID in $CONFIG_FILE"
  exit 0
fi

PLEX_URL="${PLEX_URL%/}"
log "Requesting Plex library refresh: section=$PLEX_SECTION_ID url=$PLEX_URL"

if curl -fsS "$PLEX_URL/library/sections/$PLEX_SECTION_ID/refresh?X-Plex-Token=$PLEX_TOKEN" >/dev/null; then
  log "DONE Plex refresh requested"
else
  rc=$?
  log "FAILED Plex refresh request rc=$rc"
  exit "$rc"
fi
