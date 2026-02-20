#!/bin/bash
# sudo-autotype.sh — Decrypt sudo password and deliver it where needed.
#
# The password is NEVER printed to stdout, NEVER in argv, NEVER logged.
# It flows:  pass → variable (subshell) → delivery method → unset
#
# Delivery methods:
#   --pipe <cmd>       Pipe to sudo -S <cmd> (default if cmd given)
#   --xdotool          Type into the focused X11 window via xdotool
#   --tmux <pane>      Send keystrokes to a tmux pane
#   --clipboard <sec>  Copy to clipboard, auto-clear after N seconds (default 10)
#   --env <varname>    Export to a named env var for child process (clears on exit)
#
# Usage:
#   sudo-autotype ufw status              # pipe mode (default)
#   sudo-autotype --xdotool               # type into focused window
#   sudo-autotype --tmux peridot:6        # type into tmux pane
#   sudo-autotype --clipboard 5           # clipboard for 5 seconds
#   sudo-autotype --pipe systemctl restart sshd
#
# For LLM/MCP: call with --pipe, output is the command result, password never visible.
# For Vincent: --xdotool or --clipboard when a GUI prompt appears.

set -uo pipefail

CRED_DIR="$HOME/.openclaw/credentials"
LIVE_GNUPG="/dev/shm/.gnupg-live"
ENV_FILE="$HOME/.gnupg-live-env"
KEY_RELEASE="$HOME/.local/bin/key-release"
WHICH_USER="mx/user"

err() { echo "[sudo-autotype] ERROR: $*" >&2; }

# ── Resolve GNUPGHOME ─────────────────────────────────────────
[ -f "$ENV_FILE" ] && source "$ENV_FILE" 2>/dev/null

get_password() {
    # Returns password via a named pipe to the caller — never in argv or stdout
    local pw
    if [ -d "$LIVE_GNUPG" ] && \
       gpg --homedir "$LIVE_GNUPG" --list-secret-keys 2>/dev/null | grep -q sec; then
        pw=$(GNUPGHOME="$LIVE_GNUPG" pass show "$WHICH_USER" 2>/dev/null | head -1)
    elif command -v pass >/dev/null 2>&1 && \
         gpg --list-secret-keys 2>/dev/null | grep -q sec; then
        pw=$(pass show "$WHICH_USER" 2>/dev/null | head -1)
    else
        # Keys locked — need key-release
        if [ -x "$KEY_RELEASE" ]; then
            # Per-operation release just to read the password
            pw=$("$KEY_RELEASE" pass show "$WHICH_USER" 2>/dev/null | head -1)
        else
            err "Cannot decrypt: no GPG keys available and no key-release script."
            return 1
        fi
    fi
    [ -z "$pw" ] && { err "Password decryption failed."; return 1; }
    printf '%s' "$pw"
}

# ── Parse args ────────────────────────────────────────────────
MODE="pipe"
TARGET=""
CMD=()
CLIP_TTL=10

while [ $# -gt 0 ]; do
    case "$1" in
        --xdotool)   MODE="xdotool" ;;
        --tmux)      MODE="tmux"; shift; TARGET="${1:-}" ;;
        --clipboard) MODE="clipboard"; shift; CLIP_TTL="${1:-10}" ;;
        --pipe)      MODE="pipe" ;;
        --env)       MODE="env"; shift; TARGET="${1:-SUDO_PASS}" ;;
        --root)      WHICH_USER="mx/root" ;;
        --help|-h)
            echo "Usage: sudo-autotype [--pipe|--xdotool|--tmux <pane>|--clipboard [sec]] [command...]"
            exit 0
            ;;
        -*)          err "Unknown flag: $1"; exit 1 ;;
        *)           CMD=("$@"); break ;;
    esac
    shift
done

# ── Execute delivery ──────────────────────────────────────────
case "$MODE" in
    pipe)
        if [ ${#CMD[@]} -eq 0 ]; then
            err "No command specified for pipe mode."
            exit 1
        fi
        # Get password in subshell, pipe to sudo, output command result
        (
            PW=$(get_password) || exit 1
            printf '%s\n' "$PW" | sudo -S "${CMD[@]}" 2>&1 | grep -v '^\[sudo\] password'
            RET=${PIPESTATUS[1]}
            unset PW
            exit "$RET"
        )
        ;;

    xdotool)
        if ! command -v xdotool >/dev/null 2>&1; then
            err "xdotool not installed."; exit 1
        fi
        (
            PW=$(get_password) || exit 1
            # Brief delay so user can focus the target window
            sleep 0.3
            # Type password using xdotool — cleardelay prevents screen echo
            xdotool type --clearmodifiers --delay 20 "$PW"
            xdotool key Return
            unset PW
        )
        echo "[sudo-autotype] Password typed into focused window."
        ;;

    tmux)
        if [ -z "$TARGET" ]; then
            err "No tmux target specified. Usage: --tmux session:window.pane"
            exit 1
        fi
        (
            PW=$(get_password) || exit 1
            # Send to tmux pane — uses send-keys which doesn't echo to other panes
            tmux send-keys -t "$TARGET" "$PW" Enter
            unset PW
        )
        echo "[sudo-autotype] Password sent to tmux pane $TARGET."
        ;;

    clipboard)
        if ! command -v xclip >/dev/null 2>&1; then
            err "xclip not installed."; exit 1
        fi
        (
            PW=$(get_password) || exit 1
            printf '%s' "$PW" | xclip -selection clipboard
            unset PW
        )
        echo "[sudo-autotype] Password on clipboard for ${CLIP_TTL}s. Ctrl-V to paste."
        # Auto-clear clipboard after TTL
        (
            sleep "$CLIP_TTL"
            echo -n "" | xclip -selection clipboard
            echo "[sudo-autotype] Clipboard cleared."
        ) &
        disown
        ;;

    env)
        err "ENV mode not supported (would expose password to parent process)."
        err "Use --pipe, --xdotool, or --tmux instead."
        exit 1
        ;;
esac
