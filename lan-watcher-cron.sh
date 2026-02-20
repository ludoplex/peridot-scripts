#!/bin/bash
# lan-watcher-cron.sh — runs every 5 minutes via cron
# Executes lan-watcher binary, logs output, ntfy on binary failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

LOG="$LOGDIR/lan-watcher.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Rotate log if over threshold
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_ROTATE_BYTES" ]; then
    mv "$LOG" "${LOG}.1"
fi

log "START"

if [ ! -x "$LW_BIN" ]; then
    log "ERROR: binary not found or not executable: $LW_BIN"
    notify "lan-watcher binary missing: $LW_BIN" "LAN Watcher Error" "urgent"
    exit 1
fi

# Run with timeout, capture output
output=$("$LW_BIN" --config "$LW_CONFIG" 2>&1) || {
    code=$?
    log "ERROR: binary exited $code"
    log "$output"
    notify "lan-watcher exited with code $code" "LAN Watcher Error" "high"
    exit $code
}

log "$output"
log "END"
