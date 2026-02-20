#!/bin/bash
# lan-watcher-cron.sh — runs every 5 minutes via cron
# Executes lan-watcher binary, logs output, ntfy on binary failure

set -euo pipefail

BINARY="$HOME/workspace/clopus-watcher/bin/lan-watcher"
CONFIG="$HOME/workspace/clopus-watcher/config/lan-config.yaml"
LOG="$HOME/workspace/logs/lan-watcher.log"
NOTIFY="$HOME/.local/bin/notify-me"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Rotate log if over 10MB
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv "$LOG" "${LOG}.1"
fi

log "START"

if [ ! -x "$BINARY" ]; then
    log "ERROR: binary not found or not executable: $BINARY"
    "$NOTIFY" "lan-watcher binary missing: $BINARY" "LAN Watcher Error" "urgent" 2>/dev/null || true
    exit 1
fi

# Run with timeout, capture output
output=$("$BINARY" --config "$CONFIG" 2>&1) || {
    code=$?
    log "ERROR: binary exited $code"
    log "$output"
    "$NOTIFY" "lan-watcher exited with code $code" "LAN Watcher Error" "high" 2>/dev/null || true
    exit $code
}

log "$output"
log "END"
