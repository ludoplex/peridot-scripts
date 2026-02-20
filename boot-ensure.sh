#!/bin/bash
# boot-ensure.sh — runs @reboot (after 30s delay via cron)
# Checks all configured services after boot, sends ntfy status

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

LOG="$LOGDIR/boot-ensure.log"

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

# Check all configured services
for entry in $SERVICES; do
    name=$(echo "$entry" | cut -d: -f1)
    port=$(echo "$entry" | cut -d: -f2)
    check "$name" "$port"
done

ROUTER_STATUS="UP"
ping -c1 -W3 "$ROUTER_IP" > /dev/null 2>&1 || ROUTER_STATUS="DOWN"

MSG="Boot: UP=[$(IFS=','; echo "${UP[*]}")] DOWN=[$(IFS=','; echo "${DOWN[*]}")] Router=$ROUTER_STATUS"
log "$MSG"

PRIORITY="default"
[ ${#DOWN[@]} -gt 0 ] && PRIORITY="high"

notify "$MSG" "Boot Status" "$PRIORITY"
