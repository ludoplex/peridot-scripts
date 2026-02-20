#!/bin/bash
# daily-audit.sh — runs at 3AM daily
# Full network check, disk usage, Tor circuit, DHCP leases, ntfy summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

LOG="$LOGDIR/daily-audit.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
log "=== DAILY AUDIT START ==="

ISSUES=()

# 1. Disk space
while IFS= read -r line; do
    pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    fs=$(echo "$line" | awk '{print $6}')
    if [ "$pct" -gt 85 ]; then
        msg="DISK $fs at ${pct}%"
        log "WARN: $msg"
        ISSUES+=("$msg")
    fi
done < <(df -h / /home /var 2>/dev/null | tail -n +2)
log "Disk: OK"

# 2. Memory
MEM_FREE=$(free -m | awk '/^Mem:/{print $7}')
if [ "$MEM_FREE" -lt "$MEM_WARN_MB" ]; then
    msg="LOW MEMORY: ${MEM_FREE}MB available"
    log "WARN: $msg"
    ISSUES+=("$msg")
fi
log "Memory: ${MEM_FREE}MB free"

# 3. Services (from config)
for entry in $SERVICES; do
    name=$(echo "$entry" | cut -d: -f1)
    port=$(echo "$entry" | cut -d: -f2)
    if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
        msg="SERVICE DOWN: $name (port $port)"
        log "WARN: $msg"
        ISSUES+=("$msg")
    fi
done
log "Services: checked"

# 4. Router reachable
if ! ping -c1 -W2 "$ROUTER_IP" > /dev/null 2>&1; then
    ISSUES+=("ROUTER UNREACHABLE: $ROUTER_IP")
    log "WARN: router unreachable"
fi

# 5. Tor circuit (if Tor is in services)
if echo "$SERVICES" | grep -q "Tor:"; then
    TOR_PORT=$(echo "$SERVICES" | tr ' ' '\n' | grep "^Tor:" | cut -d: -f2)
    TOR_STATUS=$(curl -s --socks5 "127.0.0.1:$TOR_PORT" https://check.torproject.org/api/ip 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print('Tor:' + str(d.get('IsTor',False)))" 2>/dev/null \
        || echo "Tor:check-failed")
    log "Tor circuit: $TOR_STATUS"
fi

# 6. LAN watcher DB — issues in last 24h
if [ -f "$LW_DB" ]; then
    DOWN_COUNT=$(sqlite3 "$LW_DB" \
        "SELECT COUNT(*) FROM checks WHERE status='down' AND checked_at > datetime('now','-24 hours');" \
        2>/dev/null || echo "0")
    log "LAN issues (24h): $DOWN_COUNT"
    if [ "$DOWN_COUNT" -gt "$DOWN_EVENT_THRESHOLD" ]; then
        ISSUES+=("HIGH DOWN EVENTS: $DOWN_COUNT in last 24h")
    fi
fi

# 7. Build summary
SUMMARY="Daily audit $(date '+%Y-%m-%d'): "
if [ ${#ISSUES[@]} -eq 0 ]; then
    SUMMARY="${SUMMARY}All clear."
    log "=== ALL CLEAR ==="
else
    SUMMARY="${SUMMARY}${#ISSUES[@]} issue(s): $(IFS='; '; echo "${ISSUES[*]}")"
    log "=== ISSUES: ${ISSUES[*]} ==="
fi

# 8. Send notification
notify "$SUMMARY" "Daily Audit" "default"
log "=== DAILY AUDIT END ==="
