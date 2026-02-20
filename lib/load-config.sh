#!/bin/bash
# load-config.sh — Shared config loader for all peridot scripts.
# Source this at the top of every script:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/lib/load-config.sh"
#
# Config search order (first found wins):
#   1. $PERIDOT_CONF (env var)
#   2. ~/.config/peridot/peridot.conf
#   3. $SCRIPT_DIR/peridot.conf (next to the scripts)
#   4. Built-in defaults (every variable has a safe default)

_load_peridot_config() {
    local conf=""
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"

    if [ -n "${PERIDOT_CONF:-}" ] && [ -f "$PERIDOT_CONF" ]; then
        conf="$PERIDOT_CONF"
    elif [ -f "$HOME/.config/peridot/peridot.conf" ]; then
        conf="$HOME/.config/peridot/peridot.conf"
    elif [ -f "$script_dir/peridot.conf" ]; then
        conf="$script_dir/peridot.conf"
    fi

    # Source config if found (values override defaults below)
    [ -n "$conf" ] && source "$conf"

    # ── Defaults (only set if not already defined) ────────────
    : "${PERIDOT_NAME:=agent}"
    : "${PERIDOT_EMAIL:=${PERIDOT_NAME}@$(hostname).local}"
    : "${PERIDOT_AGENT_ID:=main}"

    : "${ROUTER_IP:=192.168.1.1}"
    : "${INTERNET_TEST_IP:=1.1.1.1}"
    : "${LAN_SUBNET:=192.168.1.0/24}"
    : "${VLANS:=}"

    : "${SERVICES:=SSH:22}"
    : "${OPENCLAW_GW_PORT:=18789}"
    : "${OPENCLAW_API_PORT:=18792}"
    : "${DNS_MAIN_PORT:=53}"
    : "${DNS_WHITELIST_PORT:=5353}"
    : "${DNS_INTERNAL_PORT:=5354}"

    : "${WORKSPACE:=$HOME/workspace}"
    : "${LOGDIR:=$WORKSPACE/logs}"
    : "${SCRIPTS_DIR:=$script_dir}"
    : "${OC_HOME:=$HOME/.openclaw}"
    : "${OC_WORKSPACE:=$OC_HOME/workspace}"
    : "${CRED_DIR:=$OC_HOME/credentials}"

    : "${AW_DIR:=$WORKSPACE/activitywatch}"
    : "${KUMA_DIR:=$WORKSPACE/uptime-kuma}"
    : "${INSPECTOR_DIR:=$WORKSPACE/inspector}"
    : "${OPENSPEC_DIR:=$WORKSPACE/OpenSpec}"
    : "${MEM0_DIR:=$WORKSPACE/mem0}"
    : "${LIBRENMS_DIR:=$WORKSPACE/librenms}"
    : "${CLOPUS_DIR:=$WORKSPACE/clopus-watcher}"
    : "${LW_DB:=$CLOPUS_DIR/data/lan-watcher.db}"
    : "${LW_BIN:=$CLOPUS_DIR/bin/lan-watcher}"
    : "${LW_CONFIG:=$CLOPUS_DIR/config/lan-config.yaml}"

    : "${NOTIFY_CMD:=$HOME/.local/bin/notify-me}"
    : "${NOTIFY_TITLE_PREFIX:=}"

    : "${PASS_PREFIX:=sys}"
    : "${PW_LENGTH:=32}"
    : "${GPG_NAME:=$PERIDOT_NAME}"
    : "${GPG_EMAIL:=$PERIDOT_EMAIL}"

    : "${VAULT_FILE:=vault.luks}"
    : "${VAULT_SIZE_MB:=64}"
    : "${LUKS_NAME:=${PERIDOT_NAME}-keys}"
    : "${LUKS_LABEL:=$(echo "${PERIDOT_NAME}-KEYS" | tr '[:lower:]' '[:upper:]')}"
    : "${YUBIKEY_SLOT:=2}"

    : "${KEY_RELEASE:=$HOME/.local/bin/key-release}"
    : "${KEY_LOCK:=$HOME/.local/bin/key-lock}"
    : "${SUDO_WRAP:=$HOME/.local/bin/sudo-wrap}"
    : "${LIVE_GNUPG:=/dev/shm/.gnupg-live}"
    : "${ENV_FILE:=$HOME/.gnupg-live-env}"

    : "${USB_DEVICE:=}"
    : "${USB_MOUNT:=}"
    : "${VAULT_DIR:=}"

    : "${TTL_HIGH_PRIV:=1}"
    : "${TTL_ELEVATED:=3}"
    : "${TTL_STANDARD:=5}"

    : "${QUIET_HOUR_START:=23}"
    : "${QUIET_HOUR_END:=7}"
    : "${MEM_WARN_MB:=512}"
    : "${LOG_ROTATE_BYTES:=10485760}"
    : "${DOWN_EVENT_THRESHOLD:=50}"

    : "${XDOTOOL_DELAY_MS:=20}"
    : "${XDOTOOL_PRE_DELAY:=0.3}"
    : "${CLIPBOARD_TTL:=10}"

    : "${TMUX_SESSION:=$PERIDOT_NAME}"
    : "${TMUX_WIDTH:=220}"
    : "${TMUX_HEIGHT:=55}"

    : "${AW_VERSION:=0.13.2}"
    : "${AW_PORT:=5600}"
    : "${AW_DOWNLOAD_URL:=https://github.com/ActivityWatch/activitywatch/releases/download/v${AW_VERSION}/activitywatch-v${AW_VERSION}-linux-x86_64.zip}"

    : "${NDI_PORT_RANGE:=5960-5969}"
    : "${NDI_VLAN_PAIR:=}"
    : "${MULTICAST_RANGE:=239.255.0.0/16}"
    : "${IGMP_CONFIG:=$WORKSPACE/configs/igmpproxy.conf}"

    : "${CONVERTER_DEFAULT_MODEL:=claude-opus-4-6}"
    : "${CONVERTER_DEFAULT_CWD:=$HOME}"

    # Derived
    AW_BIN="${AW_DIR}/dist/activitywatch/aw-server/aw-server"
    AW_ZIP="/tmp/aw-${AW_VERSION}.zip"
    SPEC_BIN="node ${OPENSPEC_DIR}/bin/openspec.js"
    MOUNT_POINT="/mnt/${LUKS_NAME}"
    LOCK_PID_FILE="/tmp/.key-release-lock.pid"

    # Ensure critical directories exist
    mkdir -p "$LOGDIR" "$CRED_DIR" 2>/dev/null || true
}

_load_peridot_config

# Helper: iterate VLANS
# Usage: for_each_vlan id name gateway; do echo "$id $name $gateway"; done
for_each_vlan() {
    local _vid _vname _vgw
    for _entry in $VLANS; do
        _vid=$(echo "$_entry" | cut -d: -f1)
        _vname=$(echo "$_entry" | cut -d: -f2)
        _vgw=$(echo "$_entry" | cut -d: -f3)
        eval "$1=\"$_vid\" $2=\"$_vname\" $3=\"$_vgw\""
    done
}

# Helper: iterate SERVICES
# Usage: for_each_service name port; do echo "$name $port"; done
for_each_service() {
    local _sname _sport
    for _entry in $SERVICES; do
        _sname=$(echo "$_entry" | cut -d: -f1)
        _sport=$(echo "$_entry" | cut -d: -f2)
        eval "$1=\"$_sname\" $2=\"$_sport\""
    done
}

# Helper: ntfy notify
notify() {
    local msg="$1" title="${2:-}" priority="${3:-default}"
    [ -n "$NOTIFY_TITLE_PREFIX" ] && title="$NOTIFY_TITLE_PREFIX $title"
    "$NOTIFY_CMD" "$msg" "$title" "$priority" 2>/dev/null || true
}
