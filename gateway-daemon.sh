#!/bin/bash
# gateway-daemon.sh — Manage the OpenClaw gateway as a background daemon.
# sysvinit compatible (no systemd). Uses PID file for lifecycle.
#
# Usage: gateway-daemon.sh {start|stop|restart|status}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/load-config.sh"

PIDFILE="$OC_HOME/run/gateway.pid"
LOGFILE="/tmp/openclaw-gateway.log"
PORT="$OPENCLAW_GW_PORT"
BIND="loopback"

mkdir -p "$(dirname "$PIDFILE")"

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null && \
    nc -z 127.0.0.1 "$PORT" 2>/dev/null
}

do_start() {
    if is_running; then
        echo "Gateway already running (PID $(cat "$PIDFILE"), port $PORT)"
        return 0
    fi

    # Clean stale PID
    rm -f "$PIDFILE"

    echo "Starting OpenClaw gateway on :${PORT}..."
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
        nohup openclaw gateway run --bind "$BIND" --port "$PORT" \
        >> "$LOGFILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PIDFILE"

    # Wait for port
    local tries=0
    while [ $tries -lt 20 ]; do
        nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
        sleep 0.5
        tries=$((tries + 1))
    done

    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
        echo "Gateway started (PID $pid, port $PORT)"
        return 0
    else
        echo "Gateway failed to start within 10s" >&2
        rm -f "$PIDFILE"
        return 1
    fi
}

do_stop() {
    if [ ! -f "$PIDFILE" ]; then
        echo "Gateway not running (no PID file)"
        return 0
    fi

    local pid
    pid=$(cat "$PIDFILE")
    echo "Stopping gateway (PID $pid)..."
    kill "$pid" 2>/dev/null

    local tries=0
    while [ $tries -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.5
        tries=$((tries + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "Force killing..."
        kill -9 "$pid" 2>/dev/null
    fi

    rm -f "$PIDFILE"
    echo "Gateway stopped."
}

do_status() {
    if is_running; then
        local pid
        pid=$(cat "$PIDFILE")
        local uptime_s
        uptime_s=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
        echo "Gateway running (PID $pid, port $PORT, uptime ${uptime_s:-?}s)"
        return 0
    else
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
