#!/bin/bash
# gateway-watchdog.sh — Cron job (every minute) to ensure gateway is alive.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

LOG="$LOGDIR/gateway-watchdog.log"

if nc -z 127.0.0.1 "$OPENCLAW_GW_PORT" 2>/dev/null; then
    exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Gateway down — restarting" >> "$LOG"
"$SCRIPT_DIR/gateway-daemon.sh" start >> "$LOG" 2>&1

if nc -z 127.0.0.1 "$OPENCLAW_GW_PORT" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Gateway restarted OK" >> "$LOG"
    notify "OpenClaw gateway was down — auto-restarted" "Gateway Watchdog" "high"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Gateway restart FAILED" >> "$LOG"
    notify "OpenClaw gateway restart FAILED" "Gateway Watchdog" "urgent"
fi
