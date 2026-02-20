#!/bin/bash
# heartbeat-trigger.sh — runs every 15 minutes via cron
# POSTs HEARTBEAT.md prompt to openclaw agent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

OPENCLAW_JSON="$OC_HOME/openclaw.json"
HEARTBEAT="$OC_WORKSPACE/HEARTBEAT.md"
LOG="$LOGDIR/heartbeat.log"
GATEWAY="http://127.0.0.1:${OPENCLAW_GW_PORT}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Quiet hours
hour=$(date +%H)
if [ "$hour" -ge "$QUIET_HOUR_START" ] || [ "$hour" -lt "$QUIET_HOUR_END" ]; then
    log "QUIET HOURS — skipping heartbeat"
    exit 0
fi

# Extract token from openclaw.json
TOKEN=$(python3 -c "
import json, sys
with open('$OPENCLAW_JSON') as f:
    d = json.load(f)
print(d['gateway']['auth']['token'])
" 2>/dev/null)

if [ -z "$TOKEN" ]; then
    log "ERROR: could not read gateway token"
    exit 1
fi

# Build prompt from HEARTBEAT.md
PROMPT="Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK."
if [ -f "$HEARTBEAT" ]; then
    CONTENT=$(cat "$HEARTBEAT")
    PROMPT="$PROMPT

--- HEARTBEAT.md ---
$CONTENT"
fi

# Check openclaw is alive
if ! curl -sf "$GATEWAY/api/health" > /dev/null 2>&1; then
    log "WARN: openclaw gateway not responding"
    notify "OpenClaw gateway down — heartbeat skipped" "Heartbeat Warning" "high"
    exit 1
fi

# POST to openclaw
PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$PROMPT")
RESPONSE=$(curl -sf \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$PAYLOAD" \
    "$GATEWAY/api/agents/${PERIDOT_AGENT_ID}/message" 2>&1) || {
    log "ERROR: POST to openclaw failed: $RESPONSE"
    exit 1
}

log "HEARTBEAT SENT — response: ${RESPONSE:0:100}"

# Update heartbeat state
python3 -c "
import json, time, os
state_file = os.path.expanduser('$OC_WORKSPACE/memory/heartbeat-state.json')
state = {}
try:
    with open(state_file) as f:
        state = json.load(f)
except:
    pass
state['lastHeartbeat'] = int(time.time())
with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true
