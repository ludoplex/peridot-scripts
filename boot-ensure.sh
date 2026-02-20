#!/bin/bash
# boot-ensure.sh — runs @reboot (after 30s delay via cron)
# Checks all services after boot, sends ntfy status

NOTIFY="$HOME/.local/bin/notify-me"
LOG="$HOME/workspace/logs/boot-ensure.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
log "Boot check starting"

sleep 30

UP=()
DOWN=()

check() {
    local name=$1 port=$2
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
        UP+=("$name")
    else
        DOWN+=("$name")
    fi
}

check "OpenClaw" 18789
check "SSH" 22
check "Tor" 9050

ROUTER_STATUS="UP"
ping -c1 -W3 192.168.1.1 > /dev/null 2>&1 || ROUTER_STATUS="DOWN"

MSG="Boot: UP=[$(IFS=','; echo "${UP[*]}")] DOWN=[$(IFS=','; echo "${DOWN[*]}")] Router=$ROUTER_STATUS"
log "$MSG"

PRIORITY="default"
[ ${#DOWN[@]} -gt 0 ] && PRIORITY="high"

"$NOTIFY" "$MSG" "mx Boot Status" "$PRIORITY" 2>/dev/null || true
