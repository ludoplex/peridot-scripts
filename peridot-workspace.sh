#!/bin/bash
# Peridot Workspace — tmux layout for autonomous LAN management
# Configure via ~/.config/peridot/peridot.conf or peridot.conf.example
# Usage: bash ~/workspace/scripts/peridot-workspace.sh
# To reattach: tmux attach -t $TMUX_SESSION

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

SESSION="$TMUX_SESSION"
INSP_DIR="$INSPECTOR_DIR"
SPEC_DIR="$OPENSPEC_DIR"

tmux kill-session -t "$SESSION" 2>/dev/null
sleep 1

# ═══════════════════════════════════════════════════════════════════
# WINDOW 0: peridot — OpenClaw agent chat (full window)
# ═══════════════════════════════════════════════════════════════════
tmux new-session -d -s "$SESSION" -n "$PERIDOT_NAME" -x "$TMUX_WIDTH" -y "$TMUX_HEIGHT"
tmux send-keys -t "$SESSION:$PERIDOT_NAME" "openclaw agent --agent $PERIDOT_AGENT_ID" Enter

# ═══════════════════════════════════════════════════════════════════
# WINDOW 1: services — Core monitoring stack
#   AW :5600 | Kuma :3001 | OC Gateway log | MCP Inspector :6274
# ═══════════════════════════════════════════════════════════════════
tmux new-window -t "$SESSION:1" -n "services"

# Pane 0: ActivityWatch + agent buckets
tmux send-keys -t "$SESSION:services.0" "\
if [ -x '$AW_BIN' ]; then
  echo '[AW] Starting ActivityWatch — http://localhost:5600'
  echo 'Agent buckets: lan-monitor, heartbeat, memory, router-api, vlan-changes, alerts, coding'
  '$AW_BIN' --testing 2>&1 | tee $LOGDIR/activitywatch.log
elif [ -f '$AW_ZIP' ]; then
  echo '[AW] Extracting from $AW_ZIP...'
  mkdir -p '$AW_DIR/dist' && unzip -qo '$AW_ZIP' -d '$AW_DIR/dist/' && echo 'Extracted.'
  [ -x '$AW_BIN' ] && '$AW_BIN' --testing 2>&1 | tee $LOGDIR/activitywatch.log || echo 'ERROR: aw-server not found after extract'
else
  echo '[AW] NOT INSTALLED — http://localhost:5600'
  echo 'Download: wget -q https://github.com/ActivityWatch/activitywatch/releases/download/v0.13.2/activitywatch-v0.13.2-linux-x86_64.zip -O /tmp/aw.zip'
  echo ''
  echo 'Agent logger: ~/workspace/scripts/aw-agent-logger.py'
  echo 'Buckets to create:'
  echo '  aw-agent-lan-monitor    — LAN watcher probe results'
  echo '  aw-agent-heartbeat      — 15-min heartbeat events'
  echo '  aw-agent-memory         — Memory consolidation events'
  echo '  aw-agent-router-api     — Router config changes'
  echo '  aw-agent-vlan-changes   — VLAN configuration events'
  echo '  aw-agent-alerts         — ntfy alert log'
  echo '  aw-agent-coding         — Coding agent activity'
fi" Enter

# Pane 1: Uptime Kuma
tmux split-window -t "$SESSION:services" -h
tmux send-keys -t "$SESSION:services.1" "\
echo '[KUMA] Uptime Kuma — http://localhost:3001'
cd '$KUMA_DIR' 2>/dev/null || { echo 'NOT INSTALLED: clone uptime-kuma to ~/workspace/'; exit 1; }
[ ! -d node_modules ] && echo 'Installing deps...' && npm install --production 2>&1 | tail -5
if nc -z localhost 3001 2>/dev/null; then
  echo 'PORT 3001 IN USE — already running'
else
  node server/server.js 2>&1 | tee $LOGDIR/uptime-kuma.log
fi" Enter

# Pane 2: OpenClaw gateway log
tmux split-window -t "$SESSION:services.0" -v
tmux send-keys -t "$SESSION:services.2" "\
echo '[OC-GW] OpenClaw Gateway — ws://localhost:18789 API :18792'
LOGF='/tmp/openclaw-gateway.log'
[ -f \"\$LOGF\" ] || LOGF=\"/tmp/openclaw-\$(id -u)/openclaw-\$(date +%Y-%m-%d).log\"
[ -f \"\$LOGF\" ] || LOGF=\"/tmp/openclaw-1000/openclaw-\$(date +%Y-%m-%d).log\"
if [ -f \"\$LOGF\" ]; then
  echo \"Tailing: \$LOGF\"
  tail -f \"\$LOGF\"
else
  echo 'No gateway log. Start: openclaw gateway run --bind loopback'
  while [ ! -f /tmp/openclaw-gateway.log ]; do sleep 5; done
  tail -f /tmp/openclaw-gateway.log
fi" Enter

# Pane 3: MCP Inspector
tmux split-window -t "$SESSION:services.1" -v
tmux send-keys -t "$SESSION:services.3" "\
echo '[INSP] MCP Inspector — http://localhost:6274'
cd '$INSP_DIR' 2>/dev/null || { echo 'NOT INSTALLED: clone inspector to ~/workspace/'; exit 1; }
[ ! -d node_modules ] && echo 'Installing deps...' && npm install 2>&1 | tail -5
if nc -z localhost 6274 2>/dev/null; then echo 'PORT 6274 IN USE'; else npm run dev 2>&1 | tee $LOGDIR/inspector.log; fi" Enter

tmux select-layout -t "$SESSION:services" tiled

# ═══════════════════════════════════════════════════════════════════
# WINDOW 2: monitor — System + Cron + LAN DB + Processes
#   SysStats | Cron/Ops schedule | Clopus DB queries | Top/Connections
# ═══════════════════════════════════════════════════════════════════
tmux new-window -t "$SESSION:2" -n "monitor"

# Pane 0: System stats + all ports
tmux send-keys -t "$SESSION:monitor.0" "\
watch -n5 'echo \"=== \$(date) ===\"
free -h | head -3
echo
df -h / /home 2>/dev/null | tail -2
echo
echo \"=== All Listening Ports ===\"
ss -tlnp 2>/dev/null | awk \"NR>1 {printf \\\"  %-25s %s\n\\\", \\\$4, \\\$6}\" | sort'" Enter

# Pane 1: Operational rhythms — cron status + heartbeat + ntfy
tmux split-window -t "$SESSION:monitor" -h
tmux send-keys -t "$SESSION:monitor.1" "\
watch -n30 'echo \"=== Operational Rhythms ===\"
echo \"--- Cron Schedule (SOUL.md) ---\"
echo \"  5min   lan-watcher    — LAN probes -> SQLite\"
echo \"  15min  heartbeat      — service check + HEARTBEAT.md\"
echo \"  6hr    mem0 consolidate\"
echo \"  3AM    daily audit    — disk, Tor, DHCP, services\"
echo \"  4AM Sun weekly review — advisory triad\"
echo
echo \"--- Last Cron Runs ---\"
for f in lan-watcher heartbeat daily-audit boot-ensure; do
  if [ -f ~/workspace/logs/\$f.log ]; then
    last=\$(tail -1 ~/workspace/logs/\$f.log 2>/dev/null | grep -oP \"\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}\" | head -1)
    echo \"  \$f: \${last:-unknown}\"
  else
    echo \"  \$f: no log\"
  fi
done
echo
echo \"--- ntfy (openclaw-50d45f4b3e04) ---\"
echo \"  Script: ~/.local/bin/notify-me\"
echo \"  Last alert: \$(tail -1 ~/workspace/logs/alerts.log 2>/dev/null || echo none)\"'" Enter

# Pane 2: Clopus-watcher DB queries (actual probe data)
tmux split-window -t "$SESSION:monitor.0" -v
tmux send-keys -t "$SESSION:monitor.2" "\
watch -n60 'echo \"=== LAN Watcher — Recent Probes ===\"
if [ -f $LW_DB ]; then
  echo \"--- Last 20min checks ---\"
  sqlite3 -header -column $LW_DB \"SELECT host, status, latency_ms, checked_at FROM checks WHERE checked_at > datetime(\\\"now\\\",\\\"-20 minutes\\\") ORDER BY checked_at DESC LIMIT 15;\" 2>/dev/null
  echo
  echo \"--- DOWN in last 24h ---\"
  sqlite3 $LW_DB \"SELECT host, COUNT(*) as downs, MAX(checked_at) as last_down FROM checks WHERE status!=\\\"ok\\\" AND checked_at > datetime(\\\"now\\\",\\\"-24 hours\\\") GROUP BY host ORDER BY downs DESC LIMIT 10;\" 2>/dev/null
else
  echo \"DB not found: $LW_DB\"
  echo \"Binary: ~/workspace/clopus-watcher/bin/lan-watcher\"
  echo \"Config: ~/workspace/clopus-watcher/config/lan-config.yaml\"
fi'" Enter

# Pane 3: Process tree + active connections
tmux split-window -t "$SESSION:monitor.1" -v
tmux send-keys -t "$SESSION:monitor.3" "\
watch -n5 'echo \"=== Top Processes (CPU) ===\"
ps aux --sort=-%cpu | head -8
echo
echo \"=== Established Connections ===\"
ss -tnp 2>/dev/null | grep ESTAB | awk \"{printf \\\"  %-22s <-> %-22s %s\n\\\", \\\$4, \\\$5, \\\$6}\" | head -10
echo
echo \"=== Network I/O ===\"
cat /proc/net/dev 2>/dev/null | awk \"NR>2 && \\\$2+0>0 {printf \\\"  %-12s RX:%10d TX:%10d\n\\\", \\\$1, \\\$2, \\\$10}\"'" Enter

tmux select-layout -t "$SESSION:monitor" tiled

# ═══════════════════════════════════════════════════════════════════
# WINDOW 3: network — VLAN reachability + SmokePing + LibreNMS + DNS
#   VLAN Ping | SmokePing | LibreNMS | DNS/IGMP/QoS status
# ═══════════════════════════════════════════════════════════════════
tmux new-window -t "$SESSION:3" -n "network"

# Pane 0: VLAN gateway reachability + router
tmux send-keys -t "$SESSION:network.0" "\
watch -n10 'echo \"=== VLAN Gateway Reachability ===\"
echo \"--- Core ---\"
ping -c1 -W2 $ROUTER_IP >/dev/null 2>&1 && echo \"  OK  Router       $ROUTER_IP\" || echo \"  XX  Router       $ROUTER_IP  DOWN\"
ping -c1 -W2 $INTERNET_TEST_IP >/dev/null 2>&1 && echo \"  OK  Internet     $INTERNET_TEST_IP\" || echo \"  XX  Internet     $INTERNET_TEST_IP  DOWN\"
VLANS=\"$VLANS\"
if [ -n \"\$VLANS\" ]; then
  echo \"--- VLANs ---\"
  for spec in \$VLANS; do
    v=\$(echo \$spec | cut -d: -f1); n=\$(echo \$spec | cut -d: -f2); gw=\$(echo \$spec | cut -d: -f3)
    ping -c1 -W1 \$gw >/dev/null 2>&1 && echo \"  OK  VLAN\$v \$n  \$gw\" || echo \"  --  VLAN\$v \$n  \$gw\"
  done
fi'" Enter

# Pane 1: SmokePing
tmux split-window -t "$SESSION:network" -h
tmux send-keys -t "$SESSION:network.1" "\
echo '[SMOKE] SmokePing — http://localhost/cgi-bin/smokeping.cgi'
if command -v smokeping >/dev/null 2>&1; then
  smokeping --check 2>&1 || echo 'Config check failed'
  echo 'Tailing SmokePing log...'
  tail -f /var/log/smokeping/smokeping.log 2>/dev/null || tail -f /var/log/syslog 2>/dev/null | grep -i smoke
else
  echo 'SmokePing NOT INSTALLED'
  echo 'Install: sudo apt-get install -y smokeping'
  echo ''
  echo 'Targets for /etc/smokeping/config.d/Targets:'
  echo \"  + Router       $ROUTER_IP\"
  echo \"  + Internet     $INTERNET_TEST_IP\"
  VLANS=\"$VLANS\"
  for spec in \$VLANS; do
    v=\$(echo \$spec | cut -d: -f1); n=\$(echo \$spec | cut -d: -f2); gw=\$(echo \$spec | cut -d: -f3)
    echo \"  + VLAN\${v}-\${n}  \$gw\"
  done
fi" Enter

# Pane 2: LibreNMS + GenieACS/TR-069
tmux split-window -t "$SESSION:network.0" -v
tmux send-keys -t "$SESSION:network.2" "\
echo '[LIBRE] LibreNMS — http://localhost/librenms'
if [ -d '$HOME/workspace/librenms' ]; then
  echo 'Repo: ~/workspace/librenms'
  nc -z localhost 80 2>/dev/null && echo 'HTTP :80 UP' || echo 'HTTP :80 DOWN (not configured yet)'
  echo ''
  echo 'SNMP v3 for PR60X router after hardening.'
  echo 'Setup: https://docs.librenms.org/Installation/Install-LibreNMS/'
else
  echo 'LibreNMS: not cloned'
fi
echo ''
echo '[TR069] GenieACS — CPE management'
if [ -d '$HOME/workspace/genieacs' ]; then
  echo 'Repo: ~/workspace/genieacs'
  echo 'GUI:  ~/workspace/genieacs-gui'
  nc -z localhost 7557 2>/dev/null && echo 'GenieACS :7557 UP' || echo 'GenieACS :7557 DOWN'
else
  echo 'GenieACS: not cloned'
fi
echo ''
echo 'Also available: eNMS, NetBox, Oxidized, NAPALM, Netmiko'
for tool in eNMS netbox oxidized napalm netmiko; do
  [ -d ~/workspace/\$tool ] && echo \"  ~/workspace/\$tool (cloned)\" || true
done" Enter

# Pane 3: DNS stack + IGMP + Tor/I2P status
tmux split-window -t "$SESSION:network.1" -v
tmux send-keys -t "$SESSION:network.3" "\
watch -n30 'echo \"=== DNS Stack Status ===\"
echo \"--- DNS instances ---\"
nc -z localhost $DNS_MAIN_PORT 2>/dev/null && echo \"  OK  Main resolver      :$DNS_MAIN_PORT\" || echo \"  --  Main resolver      :$DNS_MAIN_PORT  (not started)\"
nc -z localhost $DNS_WHITELIST_PORT 2>/dev/null && echo \"  OK  Whitelist resolver  :$DNS_WHITELIST_PORT\" || echo \"  --  Whitelist resolver  :$DNS_WHITELIST_PORT  (not started)\"
nc -z localhost $DNS_INTERNAL_PORT 2>/dev/null && echo \"  OK  Internal resolver   :$DNS_INTERNAL_PORT\" || echo \"  --  Internal resolver   :$DNS_INTERNAL_PORT  (not started)\"
echo \"--- DNSCrypt ---\"
pgrep -x dnscrypt-proxy >/dev/null 2>&1 && echo \"  OK  dnscrypt-proxy running\" || echo \"  --  dnscrypt-proxy not running\"
echo
echo \"=== Privacy/Routing ===\"
echo \"--- Tor ---\"
nc -z localhost 9050 2>/dev/null && echo \"  OK  Tor SOCKS :9050\" || echo \"  XX  Tor SOCKS :9050 DOWN\"
curl -sf --socks5 127.0.0.1:9050 --max-time 5 https://check.torproject.org/api/ip 2>/dev/null | python3 -c \"import json,sys; d=json.load(sys.stdin); print(\\\"  Circuit:\\\", d.get(\\\"IP\\\",\\\"?\\\"), \\\"IsTor:\\\", d.get(\\\"IsTor\\\"))\" 2>/dev/null || echo \"  Tor circuit: check failed\"
echo \"--- i2pd ---\"
nc -z localhost 7070 2>/dev/null && echo \"  OK  i2pd web    :7070\" || echo \"  --  i2pd web    :7070\"
nc -z localhost 4444 2>/dev/null && echo \"  OK  i2pd HTTP   :4444\" || echo \"  --  i2pd HTTP   :4444\"
nc -z localhost 4447 2>/dev/null && echo \"  OK  i2pd SOCKS  :4447\" || echo \"  --  i2pd SOCKS  :4447\"
echo
echo \"=== IGMP (NDI cross-VLAN 30<->50) ===\"
pgrep -x igmpproxy >/dev/null 2>&1 && echo \"  OK  igmpproxy running\" || echo \"  --  igmpproxy not running (install: sudo apt install igmpproxy)\"
echo \"  Config: ~/workspace/configs/igmpproxy.conf\"
echo \"  Policy: TCP/UDP 5960-5969 + mDNS 5353 + 239.255.0.0/16\"'" Enter

tmux select-layout -t "$SESSION:network" tiled

# ═══════════════════════════════════════════════════════════════════
# WINDOW 4: memory — mem0 + SOUL + Notes + OpenSpec
#   mem0 REPL | SOUL.md | Today notes | OpenSpec tasks
# ═══════════════════════════════════════════════════════════════════
tmux new-window -t "$SESSION:4" -n "memory"

# Pane 0: mem0
tmux send-keys -t "$SESSION:memory.0" "\
echo '[MEM0] mem0 — persistent agent memory'
if [ -d '$MEM0_DIR/.venv' ]; then
  source '$MEM0_DIR/.venv/bin/activate'
  python3 -c 'from mem0 import Memory; m = Memory(); print(\"mem0 ready — search: m.search(q, agent_id=\\\"main\\\")  add: m.add([...], agent_id=\\\"main\\\")\")' 2>/dev/null || echo 'mem0 import failed — check deps'
elif [ -d '$MEM0_DIR' ]; then
  echo 'Creating venv...'
  cd '$MEM0_DIR' && python3 -m venv .venv && source .venv/bin/activate && pip install -e . 2>&1 | tail -5
  python3 -c 'from mem0 import Memory; print(\"mem0 ready\")' 2>/dev/null || echo 'mem0 setup incomplete'
else
  echo 'NOT INSTALLED: git clone https://github.com/mem0ai/mem0 ~/workspace/mem0'
fi" Enter

# Pane 1: SOUL.md + IDENTITY
tmux split-window -t "$SESSION:memory" -h
tmux send-keys -t "$SESSION:memory.1" "\
watch -n30 'head -40 $OC_HOME/workspace/SOUL.md 2>/dev/null || echo \"SOUL.md not found\"
echo \"\"
echo \"=== IDENTITY ===\"
cat $OC_HOME/workspace/IDENTITY.md 2>/dev/null | head -10
echo \"\"
echo \"=== USER ===\"
cat $OC_HOME/workspace/USER.md 2>/dev/null | head -8'" Enter

# Pane 2: Today's memory log
tmux split-window -t "$SESSION:memory.0" -v
tmux send-keys -t "$SESSION:memory.2" "\
echo '[NOTES] Today agent notes'
NOTESF=\"$OC_HOME/workspace/memory/\$(date +%Y-%m-%d).md\"
touch \"\$NOTESF\"
tail -f \"\$NOTESF\"" Enter

# Pane 3: OpenSpec status + change tracking
tmux split-window -t "$SESSION:memory.1" -v
tmux send-keys -t "$SESSION:memory.3" "\
echo '[SPEC] OpenSpec — spec-driven task tracking'
cd $HOME
$SPEC_BIN list 2>/dev/null || echo 'No changes yet. Create: /opsx:new <name>'
echo '---'
$SPEC_BIN status --change complete-openclaw-tmux-setup 2>/dev/null
echo '---'
echo 'Commands:'
echo '  /opsx:new <name>    — start a change'
echo '  /opsx:ff <name>     — fast-forward all artifacts'
echo '  /opsx:apply         — implement tasks'
echo '  /opsx:verify        — check completeness'
echo '  /opsx:archive       — archive completed change'" Enter

tmux select-layout -t "$SESSION:memory" tiled

# ═══════════════════════════════════════════════════════════════════
# WINDOW 5: health — Full service health + sessions + streaming
#   All ports | OC sessions | Streaming/NDI | RustDesk/SSH
# ═══════════════════════════════════════════════════════════════════
tmux new-window -t "$SESSION:5" -n "health"

# Pane 0: Comprehensive service health (all ports from TOOLS.md)
tmux send-keys -t "$SESSION:health.0" "\
watch -n15 'echo \"=== Full Service Health ===\"
for svc in $SERVICES \"OpenClaw-API:$OPENCLAW_API_PORT\" \"Unbound-main:$DNS_MAIN_PORT\" \"Unbound-alt:$DNS_WHITELIST_PORT\"; do
  name=\$(echo \$svc | cut -d: -f1)
  port=\$(echo \$svc | cut -d: -f2)
  nc -z localhost \$port 2>/dev/null && echo \"  OK  \$name (:\$port)\" || echo \"  --  \$name (:\$port)\"
done
echo
echo \"--- RustDesk ---\"
pgrep -x rustdesk >/dev/null 2>&1 && echo \"  OK  RustDesk (ID: 1495294261)\" || echo \"  --  RustDesk not running\"'" Enter

# Pane 1: OpenClaw sessions + gateway health
tmux split-window -t "$SESSION:health" -h
tmux send-keys -t "$SESSION:health.1" "\
echo '[OC] OpenClaw Sessions & Gateway'
openclaw sessions 2>&1
echo '---'
openclaw health 2>&1
echo '---'
echo 'Session files:'
ls -lht $OC_HOME/agents/main/sessions/*.jsonl 2>/dev/null | head -8
echo '---'
echo 'Imported: claude-code-multivlan-mission (3029 msgs)'
echo 'Active:   peridot-boot'
echo ''
echo 'Token: loaded from ~/.openclaw/openclaw.json'
echo 'ntfy:  openclaw-50d45f4b3e04'
echo 'API:   POST http://127.0.0.1:18789/api/agents/main/message'" Enter

# Pane 2: Streaming/media stack status
tmux split-window -t "$SESSION:health.0" -v
tmux send-keys -t "$SESSION:health.2" "\
echo '[MEDIA] Streaming & GPU Stack'
echo ''
echo '--- NDI/DistroAV (VLAN 30 <-> 50) ---'
echo '  Ports: TCP/UDP 5960-5969'
echo '  mDNS: UDP 5353 (cross-VLAN via igmpproxy)'
echo '  Multicast: 239.255.0.0/16'
echo ''
echo '--- Streaming Repos ---'
for repo in mediamtx srs go2rtc livekit obs-studio Sunshine wolf moonlight-qt; do
  [ -d ~/workspace/\$repo ] && echo \"  ~/workspace/\$repo (cloned)\" || true
done
echo ''
echo '--- GPU Streaming ---'
echo '  Server: Sunshine (~/workspace/Sunshine)'
echo '  Client: Moonlight (~/workspace/moonlight-qt)'
echo '  Wolf:   ~/workspace/wolf'
echo ''
echo '--- Media Server ---'
[ -d ~/workspace/jellyfin ] && echo '  Jellyfin: ~/workspace/jellyfin (cloned)' || echo '  Jellyfin: not cloned'" Enter

# Pane 3: LAN watcher log (live tail)
tmux split-window -t "$SESSION:health.1" -v
tmux send-keys -t "$SESSION:health.3" "\
echo '[LAN] LAN Watcher Live Log'
touch $LOGDIR/lan-watcher.log
echo 'Binary: ~/workspace/clopus-watcher/bin/lan-watcher'
echo 'Config: ~/workspace/clopus-watcher/config/lan-config.yaml'
echo 'DB:     $LW_DB'
echo 'Cron:   every 5 minutes'
echo '--- Live log ---'
tail -f $LOGDIR/lan-watcher.log" Enter

tmux select-layout -t "$SESSION:health" tiled

# ═══════════════════════════════════════════════════════════════════
# WINDOW 6: shell — general shell
# ═══════════════════════════════════════════════════════════════════
tmux new-window -t "$SESSION:6" -n "shell"
tmux send-keys -t "$SESSION:shell" "\
echo '=== Peridot Shell ==='
echo ''
echo 'Quick commands:'
echo '  openclaw agent --agent main       — chat with agent'
echo '  openclaw sessions                 — list sessions'
echo '  openclaw health                   — gateway health'
echo '  bash /tmp/harden-mx.sh            — run hardening (needs sudo)'
echo '  sqlite3 $LW_DB                    — query LAN watcher DB'
echo '  $SPEC_BIN list                    — OpenSpec changes'
echo '  ~/.local/bin/notify-me MSG TITLE  — send ntfy'
echo '  nmap -sn 192.168.1.0/24          — LAN scan'
echo '  ip route show                     — routing table'
echo '  ~/workspace/scripts/router-api.sh — router API helper'" Enter

# ═══════════════════════════════════════════════════════════════════
# Pane titles
# ═══════════════════════════════════════════════════════════════════
tmux select-pane -t "$SESSION:services.0" -T "[AW] ActivityWatch :5600"
tmux select-pane -t "$SESSION:services.1" -T "[KUMA] Uptime Kuma :3001"
tmux select-pane -t "$SESSION:services.2" -T "[OC-GW] Gateway Log :18789"
tmux select-pane -t "$SESSION:services.3" -T "[INSP] Inspector :6274"

tmux select-pane -t "$SESSION:monitor.0" -T "[SYS] System + Ports"
tmux select-pane -t "$SESSION:monitor.1" -T "[OPS] Cron & Rhythms"
tmux select-pane -t "$SESSION:monitor.2" -T "[LW-DB] LAN Watcher DB"
tmux select-pane -t "$SESSION:monitor.3" -T "[PROC] Processes & Connections"

tmux select-pane -t "$SESSION:network.0" -T "[VLAN] Gateway Reachability"
tmux select-pane -t "$SESSION:network.1" -T "[SMOKE] SmokePing"
tmux select-pane -t "$SESSION:network.2" -T "[LIBRE] LibreNMS + TR-069"
tmux select-pane -t "$SESSION:network.3" -T "[DNS] DNS/Tor/I2P/IGMP"

tmux select-pane -t "$SESSION:memory.0" -T "[MEM0] mem0 REPL"
tmux select-pane -t "$SESSION:memory.1" -T "[SOUL] Identity"
tmux select-pane -t "$SESSION:memory.2" -T "[NOTES] Today Notes"
tmux select-pane -t "$SESSION:memory.3" -T "[SPEC] OpenSpec"

tmux select-pane -t "$SESSION:health.0" -T "[PORTS] All Services"
tmux select-pane -t "$SESSION:health.1" -T "[OC] Sessions & Gateway"
tmux select-pane -t "$SESSION:health.2" -T "[MEDIA] Streaming/NDI"
tmux select-pane -t "$SESSION:health.3" -T "[LAN] Watcher Live Log"

# ═══════════════════════════════════════════════════════════════════
# Status bar
# ═══════════════════════════════════════════════════════════════════
tmux set-option -t "$SESSION" status on
tmux set-option -t "$SESSION" status-position bottom
tmux set-option -t "$SESSION" status-style "bg=colour235,fg=colour250"
tmux set-option -t "$SESSION" status-left-length 30
tmux set-option -t "$SESSION" status-right-length 120
tmux set-option -t "$SESSION" status-left "#[fg=colour46,bold]${PERIDOT_NAME^^} #[fg=colour250]| "
tmux set-option -t "$SESSION" status-right \
  "#[fg=colour226] Win: C-b [0-6] #[fg=colour250]| Pane: C-b arrow #[fg=colour250]| Zoom: C-b z #[fg=colour250]| Detach: C-b d #[fg=colour46]| %H:%M"
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #[bold]#{pane_title} "

tmux select-window -t "$SESSION:$PERIDOT_NAME"

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════"
echo " PERIDOT WORKSPACE READY — 7 windows / 22 panes"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo " Windows (C-b [number]):"
echo "  0: peridot  — OpenClaw agent chat"
echo "  1: services — AW :5600 | Kuma :3001 | GW log | Inspector :6274"
echo "  2: monitor  — SysStats | Cron/Ops | LAN-DB queries | Processes"
echo "  3: network  — VLAN ping | SmokePing | LibreNMS/TR-069 | DNS/Tor/I2P/IGMP"
echo "  4: memory   — mem0 | SOUL/Identity | Today notes | OpenSpec"
echo "  5: health   — All ports | OC sessions | Streaming/NDI | LAN log"
echo "  6: shell    — general shell + quick commands"
echo ""
echo " Pane navigation:"
echo "  C-b arrow     — move between panes"
echo "  C-b z         — zoom/unzoom current pane"
echo "  C-b d         — detach (workspace keeps running)"
echo "  C-b [         — scroll mode (q to exit)"
echo ""
echo " Reattach: tmux attach -t peridot"
echo ""

if [ -t 0 ]; then
  tmux attach -t "$SESSION"
fi
