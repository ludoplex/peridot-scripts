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

# Pane 1: Process and connection monitor
tmux split-window -t "$SESSION:monitor" -h
tmux send-keys -t "$SESSION:monitor.1" "\
watch -n5 'echo \"=== Top Processes (CPU) ===\"
ps aux --sort=-%cpu | head -8
echo
echo \"=== Active Connections ===\"
ss -tnp 2>/dev/null | grep ESTAB | awk \"{print \\\"  \\\" \\\$4, \\\"<->\\\", \\\$5, \\\$6}\" | head -10
echo
echo \"=== Network I/O ===\"
cat /proc/net/dev 2>/dev/null | awk \"NR>2 && \\\$2+0>0 {printf \\\"  %-10s RX: %10d  TX: %10d\n\\\", \\\$1, \\\$2, \\\$10}\"'" Enter

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
# WINDOW 4: network — SmokePing + LibreNMS + network tools
# ─────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION:4" -n "network"

# Pane 0: SmokePing status
tmux send-keys -t "$SESSION:network.0" "\
echo '[SMOKE] SmokePing — http://localhost/cgi-bin/smokeping.cgi'
if command -v smokeping >/dev/null 2>&1; then
  echo 'SmokePing installed. Checking config...'
  smokeping --check 2>&1 || echo 'Config check failed'
  echo 'Tailing SmokePing log...'
  tail -f /var/log/smokeping/smokeping.log 2>/dev/null || tail -f /var/log/syslog 2>/dev/null | grep -i smoke
else
  echo 'SmokePing NOT INSTALLED'
  echo 'Install: sudo apt-get install -y smokeping'
  echo ''
  echo 'After install, configure targets in /etc/smokeping/config.d/Targets'
  echo 'Key targets for multi-VLAN:'
  echo '  + Router      192.168.1.1'
  echo '  + VLAN10-GW   10.10.10.1   (Admin)'
  echo '  + VLAN20-GW   10.10.20.1   (POS)'
  echo '  + VLAN30-GW   10.10.30.1   (GGLeap)'
  echo '  + VLAN40-GW   10.10.40.1   (PearsonVue)'
  echo '  + VLAN50-GW   10.10.50.1   (Streaming)'
  echo '  + VLAN60-GW   10.10.60.1   (Tutoring)'
  echo '  + VLAN70-GW   10.10.70.1   (Security)'
  echo '  + VLAN80-GW   10.10.80.1   (NAS)'
fi" Enter

# Pane 1: LibreNMS status
tmux split-window -t "$SESSION:network" -h
tmux send-keys -t "$SESSION:network.1" "\
echo '[LIBRE] LibreNMS — network monitoring'
if [ -d '$HOME/workspace/librenms' ]; then
  echo 'LibreNMS repo present at ~/workspace/librenms'
  echo 'Web UI: http://localhost/librenms (after setup)'
  echo ''
  echo 'Status: Check if running...'
  nc -z localhost 80 2>/dev/null && echo '  HTTP :80 UP' || echo '  HTTP :80 DOWN (not configured yet)'
  echo ''
  echo 'Quick setup: https://docs.librenms.org/Installation/Install-LibreNMS/'
else
  echo 'LibreNMS NOT CLONED'
  echo 'Clone: git clone https://github.com/librenms/librenms ~/workspace/librenms'
fi" Enter

# Pane 2: Network ping dashboard
tmux split-window -t "$SESSION:network.0" -v
tmux send-keys -t "$SESSION:network.2" "\
watch -n10 'echo \"=== Network Reachability ===\"
echo \"--- Core ---\"
ping -c1 -W2 192.168.1.1 >/dev/null 2>&1 && echo \"  OK Router (192.168.1.1)\" || echo \"  XX Router (192.168.1.1)\"
ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo \"  OK Internet (1.1.1.1)\" || echo \"  XX Internet (1.1.1.1)\"
echo \"--- VLAN Gateways ---\"
for v in 10 20 30 40 50 60 70 80; do
  gw=\"10.10.\${v}.1\"
  ping -c1 -W1 \$gw >/dev/null 2>&1 && echo \"  OK VLAN\$v (\$gw)\" || echo \"  -- VLAN\$v (\$gw) unreachable\"
done
echo \"--- DNS ---\"
dig +short +time=2 google.com 2>/dev/null | head -1 | xargs -I{} echo \"  OK DNS -> {}\" || echo \"  XX DNS failed\"'" Enter

# Pane 3: Netmiko / network tools
tmux split-window -t "$SESSION:network.1" -v
tmux send-keys -t "$SESSION:network.3" "\
echo '[NET] Network Tools'
echo 'Available tools:'
command -v nmap >/dev/null && echo '  nmap: installed' || echo '  nmap: NOT installed (apt install nmap)'
command -v mtr >/dev/null && echo '  mtr: installed' || echo '  mtr: NOT installed (apt install mtr)'
command -v iperf3 >/dev/null && echo '  iperf3: installed' || echo '  iperf3: NOT installed'
command -v netmiko >/dev/null && echo '  netmiko: installed' || echo '  netmiko: ~/workspace/netmiko (not in PATH)'
echo ''
echo 'Quick commands:'
echo '  nmap -sn 192.168.1.0/24     # LAN host scan'
echo '  mtr -c5 192.168.1.1         # Traceroute to router'
echo '  ss -tlnp                    # Listening ports'
echo '  ip route show               # Routing table'
echo '  ip addr show                # Interface IPs'" Enter

tmux select-layout -t "$SESSION:network" tiled

# ─────────────────────────────────────────────────────────────────
# WINDOW 5: shell — general shell for commands
# ─────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION:5" -n "shell"
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
tmux select-pane -t "$SESSION:monitor.1" -T "[CONN] Processes & Connections"
tmux select-pane -t "$SESSION:monitor.2" -T "[LAN] Watcher Log"
tmux select-pane -t "$SESSION:monitor.3" -T "[SPEC] OpenSpec"

tmux select-pane -t "$SESSION:memory.0" -T "[MEM0] mem0 REPL"
tmux select-pane -t "$SESSION:memory.1" -T "[SOUL] Peridot SOUL.md"
tmux select-pane -t "$SESSION:memory.2" -T "[NOTES] Today Notes"
tmux select-pane -t "$SESSION:memory.3" -T "[HEALTH] Service Health"

tmux select-pane -t "$SESSION:network.0" -T "[SMOKE] SmokePing"
tmux select-pane -t "$SESSION:network.1" -T "[LIBRE] LibreNMS"
tmux select-pane -t "$SESSION:network.2" -T "[PING] VLAN Reachability"
tmux select-pane -t "$SESSION:network.3" -T "[NET] Network Tools"

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
  "#[fg=colour226] Win: C-b [0-5] #[fg=colour250]| Pane: C-b arrow #[fg=colour250]| Zoom: C-b z #[fg=colour250]| Detach: C-b d #[fg=colour46]| %H:%M"
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
echo "  2: monitor    — SysStats | Connections | LAN | OpenSpec"
echo "  3: memory     — mem0 | SOUL | Notes | Health"
echo "  4: network    — SmokePing | LibreNMS | VLAN Ping | Net Tools"
echo "  5: shell      — general shell"
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
