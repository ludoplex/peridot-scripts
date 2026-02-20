#!/bin/bash
# launch-peridot.sh — Start gateway, rebuild tmux workspace, open terminal.
# Safe to run from Claude Code — never touches the parent terminal.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

# 1. Ensure gateway is running
"$SCRIPT_DIR/gateway-daemon.sh" start

# 2. Wait for port (max 10s)
tries=0
while [ $tries -lt 20 ]; do
    nc -z 127.0.0.1 "$OPENCLAW_GW_PORT" 2>/dev/null && break
    sleep 0.5
    tries=$((tries + 1))
done

if ! nc -z 127.0.0.1 "$OPENCLAW_GW_PORT" 2>/dev/null; then
    echo "WARNING: Gateway not responding on :$OPENCLAW_GW_PORT after 10s" >&2
fi

# 3. Rebuild tmux workspace
bash "$SCRIPT_DIR/peridot-workspace.sh"

# 4. Open terminal attached to it
nohup xfce4-terminal --title "PERIDOT" -e "tmux attach-session -t $TMUX_SESSION" >/dev/null 2>&1 &
