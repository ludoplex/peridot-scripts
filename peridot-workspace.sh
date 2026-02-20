#!/bin/bash
# Peridot Workspace — tmux layout for all services + OpenClaw agent
# Usage: bash ~/workspace/scripts/peridot-workspace.sh
# To reattach: tmux attach -t peridot

SESSION="peridot"
AW_DIR="$HOME/workspace/activitywatch"
AW_BIN="$AW_DIR/dist/activitywatch/aw-server/aw-server"
AW_ZIP="/tmp/aw.zip"
KUMA_DIR="$HOME/workspace/uptime-kuma"
INSP_DIR="$HOME/workspace/inspector"
SPEC_DIR="$HOME/workspace/OpenSpec"
SPEC_BIN="node $SPEC_DIR/bin/openspec.js"
MEM0_DIR="$HOME/workspace/mem0"
LOGDIR="$HOME/workspace/logs"
OC_HOME="$HOME/.openclaw"

# Ensure logs directory
mkdir -p "$LOGDIR"

# Kill existing session
tmux kill-session -t "$SESSION" 2>/dev/null
sleep 1

# ─────────────────────────────────────────────────────────────────
# WINDOW 0: peridot — OpenClaw agent chat (full window)
# ─────────────────────────────────────────────────────────────────
tmux new-session -d -s "$SESSION" -n "peridot" -x 220 -y 55

tmux send-keys -t "$SESSION:peridot" \
  'openclaw agent --agent main' Enter

# ─────────────────────────────────────────────────────────────────
# WINDOW 1: services — ActivityWatch + Uptime Kuma + Gateway log
# ─────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION:1" -n "services"

# Pane 0: ActivityWatch (with auto-extract)
tmux send-keys -t "$SESSION:services.0" "\
if [ -x '$AW_BIN' ]; then
  echo '[AW] Starting ActivityWatch — http://localhost:5600'
  '$AW_BIN' --testing 2>&1 | tee $LOGDIR/activitywatch.log
elif [ -f '$AW_ZIP' ]; then
  echo '[AW] Extracting ActivityWatch from $AW_ZIP...'
  mkdir -p '$AW_DIR/dist' && unzip -qo '$AW_ZIP' -d '$AW_DIR/dist/' && echo 'Extracted.'
  [ -x '$AW_BIN' ] && '$AW_BIN' --testing 2>&1 | tee $LOGDIR/activitywatch.log || echo 'ERROR: aw-server not found after extract'
else
  echo '[AW] NOT INSTALLED'
  echo 'Download: wget -q https://github.com/ActivityWatch/activitywatch/releases/download/v0.13.2/activitywatch-v0.13.2-linux-x86_64.zip -O /tmp/aw.zip'
  echo 'Then re-run this workspace script.'
fi" Enter

# Pane 1: Uptime Kuma (with dep check)
tmux split-window -t "$SESSION:services" -h
tmux send-keys -t "$SESSION:services.1" "\
echo '[KUMA] Uptime Kuma — http://localhost:3001'
cd '$KUMA_DIR' 2>/dev/null || { echo 'NOT INSTALLED: clone uptime-kuma to ~/workspace/'; exit 1; }
if [ ! -d node_modules ]; then
  echo 'Installing dependencies...'
  npm install --production 2>&1 | tail -5
fi
if nc -z localhost 3001 2>/dev/null; then
  echo 'PORT 3001 ALREADY IN USE — skipping start'
else
  node server/server.js 2>&1 | tee $LOGDIR/uptime-kuma.log
fi" Enter

# Pane 2: OpenClaw gateway log (dynamic path)
tmux split-window -t "$SESSION:services.0" -v
tmux send-keys -t "$SESSION:services.2" "\
echo '[OC-GW] OpenClaw Gateway Log'
LOGF='/tmp/openclaw-gateway.log'
[ -f \"\$LOGF\" ] || LOGF=\"/tmp/openclaw-\$(id -u)/openclaw-\$(date +%Y-%m-%d).log\"
[ -f \"\$LOGF\" ] || LOGF=\"/tmp/openclaw-1000/openclaw-\$(date +%Y-%m-%d).log\"
if [ -f \"\$LOGF\" ]; then
  echo \"Tailing: \$LOGF\"
  tail -f \"\$LOGF\"
else
  echo 'No gateway log found. Gateway may not be running.'
  echo 'Start with: openclaw gateway run --bind loopback'
  echo 'Waiting for log...'
  while [ ! -f /tmp/openclaw-gateway.log ]; do sleep 5; done
  tail -f /tmp/openclaw-gateway.log
fi" Enter

# Pane 3: MCP Inspector (with build check)
tmux split-window -t "$SESSION:services.1" -v
tmux send-keys -t "$SESSION:services.3" "\
echo '[INSP] MCP Inspector — http://localhost:6274'
cd '$INSP_DIR' 2>/dev/null || { echo 'NOT INSTALLED: clone inspector to ~/workspace/'; exit 1; }
if [ ! -d node_modules ]; then
  echo 'Installing dependencies...'
  npm install 2>&1 | tail -5
fi
if nc -z localhost 6274 2>/dev/null; then
  echo 'PORT 6274 ALREADY IN USE — skipping start'
else
  npm run dev 2>&1 | tee $LOGDIR/inspector.log
fi" Enter

tmux select-layout -t "$SESSION:services" tiled

# ─────────────────────────────────────────────────────────────────
# WINDOW 2: monitor — System stats + Hardening + LAN + OpenSpec
# ─────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION:2" -n "monitor"

# Pane 0: System stats (no sudo needed)
tmux send-keys -t "$SESSION:monitor.0" "\
watch -n3 'echo \"=== \$(date) ===\"
free -h
echo
df -h /home /tmp 2>/dev/null
echo
echo \"=== LISTENING (localhost) ===\"
ss -tlnp 2>/dev/null | grep 127.0.0 | head -10
echo
echo \"=== LISTENING (0.0.0.0 — EXPOSED) ===\"
ss -tlnp 2>/dev/null | grep \"0.0.0.0\" | grep -v 127'" Enter

# Pane 1: Hardening status (no sudo — reads files + ss)
tmux split-window -t "$SESSION:monitor" -h
tmux send-keys -t "$SESSION:monitor.1" "\
watch -n30 'echo \"=== HARDENING STATUS ===\"
echo
echo \"--- SSH Config ---\"
grep -E \"^(Password|PermitRoot|Pubkey|Challenge)\" /etc/ssh/sshd_config 2>/dev/null || echo \"Cannot read sshd_config\"
echo
echo \"--- Firewall ---\"
if command -v ufw >/dev/null 2>&1; then
  if [ -f /etc/ufw/user.rules ]; then
    echo \"UFW rules found:\"
    grep -c \"^-A\" /etc/ufw/user.rules 2>/dev/null | xargs -I{} echo \"  {} rules defined\"
    grep \"dport\" /etc/ufw/user.rules 2>/dev/null | head -8
  else
    echo \"UFW: NOT CONFIGURED\"
  fi
else
  echo \"UFW: NOT INSTALLED\"
fi
echo
echo \"--- Exposed Ports (0.0.0.0) ---\"
ss -tlnp 2>/dev/null | grep \"0.0.0.0\" | grep -v 127 | awk \"{print \\\"  \\\" \\\$4, \\\$6}\" | head -10
echo
echo \"--- rpcbind ---\"
ss -tlnp 2>/dev/null | grep \":111\" >/dev/null && echo \"  ACTIVE (should be disabled)\" || echo \"  disabled\"'" Enter

# Pane 2: LAN Watcher log
tmux split-window -t "$SESSION:monitor.0" -v
tmux send-keys -t "$SESSION:monitor.2" "\
echo '[LAN] LAN Watcher — every 5min via cron'
touch $LOGDIR/lan-watcher.log
tail -f $LOGDIR/lan-watcher.log" Enter

# Pane 3: OpenSpec status
tmux split-window -t "$SESSION:monitor.1" -v
tmux send-keys -t "$SESSION:monitor.3" "\
echo '[SPEC] OpenSpec Status'
cd $HOME
$SPEC_BIN list 2>/dev/null || echo 'No changes yet'
echo '---'
echo 'Commands: node $SPEC_DIR/bin/openspec.js <cmd>'
echo '  list                  — list changes'
echo '  status --change NAME  — show artifact progress'
echo '  view                  — interactive dashboard'
echo '---'
$SPEC_BIN status --change complete-openclaw-tmux-setup 2>/dev/null" Enter

tmux select-layout -t "$SESSION:monitor" tiled

# ─────────────────────────────────────────────────────────────────
# WINDOW 3: memory — mem0 + SOUL + Notes + Service health
# ─────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION:3" -n "memory"

# Pane 0: mem0
tmux send-keys -t "$SESSION:memory.0" "\
echo '[MEM0] mem0 — persistent agent memory'
if [ -d '$MEM0_DIR/.venv' ]; then
  source '$MEM0_DIR/.venv/bin/activate'
  python3 -c 'from mem0 import Memory; m = Memory(); print(\"mem0 ready\")' 2>/dev/null || echo 'mem0 import failed'
elif [ -d '$MEM0_DIR' ]; then
  echo 'Creating venv...'
  cd '$MEM0_DIR' && python3 -m venv .venv && source .venv/bin/activate && pip install -e . 2>&1 | tail -5
  python3 -c 'from mem0 import Memory; print(\"mem0 ready\")' 2>/dev/null || echo 'mem0 setup incomplete'
else
  echo 'NOT INSTALLED: clone mem0 to ~/workspace/'
fi" Enter

# Pane 1: SOUL.md viewer
tmux split-window -t "$SESSION:memory" -h
tmux send-keys -t "$SESSION:memory.1" "\
watch -n30 'head -60 $OC_HOME/workspace/SOUL.md 2>/dev/null || echo \"SOUL.md not found\"'" Enter

# Pane 2: Today's memory log
tmux split-window -t "$SESSION:memory.0" -v
tmux send-keys -t "$SESSION:memory.2" "\
echo '[NOTES] Today agent notes'
NOTESF=\"$OC_HOME/workspace/memory/\$(date +%Y-%m-%d).md\"
touch \"\$NOTESF\"
tail -f \"\$NOTESF\"" Enter

# Pane 3: Service health (no sudo)
tmux split-window -t "$SESSION:memory.1" -v
tmux send-keys -t "$SESSION:memory.3" "\
watch -n15 'echo \"=== Service Health ===\"
for svc in \"OpenClaw:18789\" \"SSH:22\" \"Tor:9050\" \"ActivityWatch:5600\" \"Uptime-Kuma:3001\" \"Inspector:6274\"; do
  name=\$(echo \$svc | cut -d: -f1)
  port=\$(echo \$svc | cut -d: -f2)
  nc -z localhost \$port 2>/dev/null && echo \"  OK \$name (:\$port)\" || echo \"  XX \$name (:\$port) DOWN\"
done
echo
echo \"=== OpenClaw Gateway ===\"
openclaw health 2>&1 | head -5
echo
echo \"=== Recent Logs ===\"
ls -lt ~/workspace/logs/*.log 2>/dev/null | head -5'" Enter

tmux select-layout -t "$SESSION:memory" tiled

# ─────────────────────────────────────────────────────────────────
# WINDOW 4: shell — general shell for commands
# ─────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION:4" -n "shell"
tmux send-keys -t "$SESSION:shell" \
  "echo 'Shell — full access. Hardening script: bash /tmp/harden-mx.sh'" Enter

# ─────────────────────────────────────────────────────────────────
# Pane titles
# ─────────────────────────────────────────────────────────────────
tmux select-pane -t "$SESSION:services.0" -T "[AW] ActivityWatch :5600"
tmux select-pane -t "$SESSION:services.1" -T "[KUMA] Uptime Kuma :3001"
tmux select-pane -t "$SESSION:services.2" -T "[OC-GW] Gateway Log"
tmux select-pane -t "$SESSION:services.3" -T "[INSP] Inspector :6274"

tmux select-pane -t "$SESSION:monitor.0" -T "[SYS] System Stats"
tmux select-pane -t "$SESSION:monitor.1" -T "[HARDEN] Security Status"
tmux select-pane -t "$SESSION:monitor.2" -T "[LAN] Watcher Log"
tmux select-pane -t "$SESSION:monitor.3" -T "[SPEC] OpenSpec"

tmux select-pane -t "$SESSION:memory.0" -T "[MEM0] mem0 REPL"
tmux select-pane -t "$SESSION:memory.1" -T "[SOUL] Peridot SOUL.md"
tmux select-pane -t "$SESSION:memory.2" -T "[NOTES] Today Notes"
tmux select-pane -t "$SESSION:memory.3" -T "[HEALTH] Service Health"

# ─────────────────────────────────────────────────────────────────
# Status bar + key bindings
# ─────────────────────────────────────────────────────────────────
tmux set-option -t "$SESSION" status on
tmux set-option -t "$SESSION" status-position bottom
tmux set-option -t "$SESSION" status-style "bg=colour235,fg=colour250"
tmux set-option -t "$SESSION" status-left-length 30
tmux set-option -t "$SESSION" status-right-length 120
tmux set-option -t "$SESSION" status-left "#[fg=colour46,bold]PERIDOT #[fg=colour250]| "
tmux set-option -t "$SESSION" status-right \
  "#[fg=colour226] Win: C-b [0-4] #[fg=colour250]| Pane: C-b arrow #[fg=colour250]| Zoom: C-b z #[fg=colour250]| Detach: C-b d #[fg=colour46]| %H:%M"
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #[bold]#{pane_title} "

# Focus on the agent chat window
tmux select-window -t "$SESSION:peridot"

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo " PERIDOT WORKSPACE READY"
echo "════════════════════════════════════════════════════"
echo ""
echo " Windows (C-b [number]):"
echo "  0: peridot    — OpenClaw agent chat"
echo "  1: services   — AW | Kuma | OC-GW log | Inspector"
echo "  2: monitor    — SysStats | Hardening | LAN | OpenSpec"
echo "  3: memory     — mem0 | SOUL | Notes | Health"
echo "  4: shell      — general shell"
echo ""
echo " Pane navigation:"
echo "  C-b arrow     — move between panes"
echo "  C-b z         — zoom/unzoom current pane"
echo "  C-b d         — detach (workspace keeps running)"
echo "  C-b [         — scroll mode (q to exit)"
echo ""
echo " Reattach: tmux attach -t peridot"
echo ""

# Only attach if running in an interactive terminal
if [ -t 0 ]; then
  tmux attach -t "$SESSION"
fi
