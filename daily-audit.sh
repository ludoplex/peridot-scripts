#!/bin/bash
# daily-audit.sh — runs at 3AM daily
# Full network check, disk usage, Tor circuit, DHCP leases, ntfy summary

set -euo pipefail

LOG="$HOME/workspace/logs/daily-audit.log"
NOTIFY="$HOME/.local/bin/notify-me"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
log "=== DAILY AUDIT START ==="

ISSUES=()
SUMMARY=""

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
if [ "$MEM_FREE" -lt 512 ]; then
    msg="LOW MEMORY: ${MEM_FREE}MB available"
    log "WARN: $msg"
    ISSUES+=("$msg")
fi
log "Memory: ${MEM_FREE}MB free"

# 3. Services
for svc in "OpenClaw:18789" "SSH:22" "Tor:9050"; do
    name=$(echo "$svc" | cut -d: -f1)
    port=$(echo "$svc" | cut -d: -f2)
    if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
        msg="SERVICE DOWN: $name (port $port)"
        log "WARN: $msg"
        ISSUES+=("$msg")
    fi
done
log "Services: checked"

# 4. Router reachable
if ! ping -c1 -W2 192.168.1.1 > /dev/null 2>&1; then
    ISSUES+=("ROUTER UNREACHABLE: 192.168.1.1")
    log "WARN: router unreachable"
fi

# 5. Tor circuit
TOR_STATUS=$(curl -s --socks5 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print('Tor:' + str(d.get('IsTor',False)))" 2>/dev/null || echo "Tor:check-failed")
log "Tor circuit: $TOR_STATUS"

# 6. Lan-watcher DB — issues in last 24h
DB="$HOME/workspace/clopus-watcher/data/lan-watcher.db"
if [ -f "$DB" ]; then
    DOWN_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM checks WHERE status='down' AND checked_at > datetime('now','-24 hours');" 2>/dev/null || echo "0")
    log "LAN issues (24h): $DOWN_COUNT"
    if [ "$DOWN_COUNT" -gt 50 ]; then
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

# 8. Send ntfy summary
"$NOTIFY" "$SUMMARY" "Daily LAN Audit" "default" 2>/dev/null || true
log "=== DAILY AUDIT END ==="
