#!/bin/bash
# gateway-daemon.sh — Manage the OpenClaw gateway as a background daemon.
# sysvinit compatible (no systemd).
#
# The PORT is the source of truth, not the PID file.
# If something is listening on the port, the gateway is running — regardless
# of who started it or what the PID file says.
#
# Usage: gateway-daemon.sh {start|stop|restart|status}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

PIDFILE="$OC_HOME/run/gateway.pid"
LOGFILE="/tmp/openclaw-gateway.log"
PORT="$OPENCLAW_GW_PORT"
BIND="loopback"

mkdir -p "$(dirname "$PIDFILE")"

# Find the PID that owns the port — the only reliable way to know what's running.
port_owner() {
    ss -tlnp "sport = :$PORT" 2>/dev/null \
        | grep -oP 'pid=\K[0-9]+' \
        | head -1
}

port_up() {
    nc -z 127.0.0.1 "$PORT" 2>/dev/null
}

# Sync PID file to reality.
sync_pidfile() {
    local owner
    owner=$(port_owner)
    if [ -n "$owner" ]; then
        echo "$owner" > "$PIDFILE"
    else
        rm -f "$PIDFILE"
    fi
}

do_start() {
    if port_up; then
        sync_pidfile
        local owner
        owner=$(port_owner)
        echo "Gateway already running (PID $owner, port $PORT)"
        return 0
    fi

    rm -f "$PIDFILE"

    echo "Starting OpenClaw gateway on :${PORT}..."
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
        nohup openclaw gateway run --bind "$BIND" --port "$PORT" \
        >> "$LOGFILE" 2>&1 &

    # Wait for port (not PID — the gateway forks internally)
    local tries=0
    while [ $tries -lt 20 ]; do
        if port_up; then
            sync_pidfile
            echo "Gateway started (PID $(port_owner), port $PORT)"
            return 0
        fi
        sleep 0.5
        tries=$((tries + 1))
    done

    echo "Gateway failed to start within 10s" >&2
    rm -f "$PIDFILE"
    return 1
}

do_stop() {
    local owner
    owner=$(port_owner)

    if [ -z "$owner" ]; then
        echo "Gateway not running (port $PORT free)"
        rm -f "$PIDFILE"
        return 0
    fi

    echo "Stopping gateway (PID $owner on :$PORT)..."
    kill "$owner" 2>/dev/null

    local tries=0
    while [ $tries -lt 10 ] && kill -0 "$owner" 2>/dev/null; do
        sleep 0.5
        tries=$((tries + 1))
    done

    if kill -0 "$owner" 2>/dev/null; then
        echo "Force killing PID $owner..."
        kill -9 "$owner" 2>/dev/null
    fi

    rm -f "$PIDFILE"
    echo "Gateway stopped."
}

do_status() {
    if port_up; then
        sync_pidfile
        local owner
        owner=$(port_owner)
        local uptime_s
        uptime_s=$(ps -o etimes= -p "$owner" 2>/dev/null | tr -d ' ')
        echo "Gateway running (PID $owner, port $PORT, uptime ${uptime_s:-?}s)"
        return 0
    else
        rm -f "$PIDFILE"
        echo "Gateway not running"
        return 1
    fi
}

case "${1:-}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  do_status ;;
    *)       echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
