#!/bin/bash
# launch-peridot.sh — Rebuild and open the peridot tmux workspace.
# Kills existing peridot session, rebuilds it, opens a terminal attached to it.
# Safe to run from Claude Code — never touches the parent terminal.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Rebuild workspace (kills only peridot session, never the server)
bash "$SCRIPT_DIR/peridot-workspace.sh"

# Open terminal attached to it
nohup xfce4-terminal --title "PERIDOT" -e "tmux attach-session -t peridot" >/dev/null 2>&1 &
