#!/bin/bash
# setup-key-vault.sh — One-time (idempotent) setup for YubiKey-gated GPG key vault
#
# Moves GPG private keys to a LUKS-encrypted container on external USB storage.
# The LUKS passphrase is derived from a YubiKey HMAC-SHA1 challenge-response.
# After setup, `key-release <cmd>` is required to use pass/sudo-wrap.
#
# Safe to re-run — checks state at each step and skips completed phases.
#
# Usage: bash ~/workspace/scripts/setup-key-vault.sh [--vault-dir /path/to/dir]

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
VAULT_DIR=""                              # set by --vault-dir or auto-detected
VAULT_FILE="vault.luks"
VAULT_SIZE_MB=64
LUKS_NAME="peridot-keys"
MOUNT_POINT="/mnt/$LUKS_NAME"
EXPORT_DIR="gnupg-export"
CRED_DIR="$HOME/.openclaw/credentials"
GNUPG_DIR="$HOME/.gnupg"
KEY_RELEASE="$HOME/.local/bin/key-release"
KEY_LOCK="$HOME/.local/bin/key-lock"
SUDO_WRAP="$HOME/.local/bin/sudo-wrap"
TRANSCEND_DEV="/dev/sdb1"
TRANSCEND_MNT="/mnt/transcend"

log() { echo "[setup] $*"; }
die() { echo "[setup] FATAL: $*" >&2; exit 1; }

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --vault-dir) shift; VAULT_DIR="$1" ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

# ══════════════════════════════════════════════════════════════
# Phase 1: Install YubiKey packages
# ══════════════════════════════════════════════════════════════
log "Phase 1: YubiKey packages"

NEEDED=""
command -v ykman        >/dev/null 2>&1 || NEEDED="$NEEDED yubikey-manager"
command -v ykchalresp   >/dev/null 2>&1 || NEEDED="$NEEDED yubikey-personalization"
command -v pcscd        >/dev/null 2>&1 || NEEDED="$NEEDED pcscd"
dpkg -l 2>/dev/null | grep -q "libfido2-dev" || NEEDED="$NEEDED libfido2-dev"

if [ -n "$NEEDED" ]; then
    log "  Installing:$NEEDED"
    "$SUDO_WRAP" apt-get update -qq 2>/dev/null
    "$SUDO_WRAP" apt-get install -y $NEEDED 2>&1 | tail -3
else
    log "  All packages present."
fi

# Start pcscd if not running
if command -v pcscd >/dev/null 2>&1; then
    pgrep -x pcscd >/dev/null || "$SUDO_WRAP" pcscd --daemon 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════
# Phase 2: Detect YubiKey
# ══════════════════════════════════════════════════════════════
log "Phase 2: Detecting YubiKey"

detect_yubikey() {
    if command -v ykman >/dev/null 2>&1; then
        ykman info >/dev/null 2>&1 && return 0
    fi
    lsusb 2>/dev/null | grep -qi "1050:" && return 0
    return 1
}

if ! detect_yubikey; then
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║  Plug in your YubiKey and press Enter.        ║"
    echo "╚═══════════════════════════════════════════════╝"
    read -r
    sleep 2
    detect_yubikey || die "YubiKey not detected."
fi

YUBIKEY_SERIAL=$(ykman info 2>/dev/null | awk '/Serial/{print $NF}' || echo "unknown")
log "  YubiKey detected (serial: $YUBIKEY_SERIAL)"

# ══════════════════════════════════════════════════════════════
# Phase 3: Configure HMAC-SHA1 on slot 2
# ══════════════════════════════════════════════════════════════
log "Phase 3: HMAC-SHA1 configuration"

if ykman otp info 2>/dev/null | grep -q "Slot 2.*programmed"; then
    log "  Slot 2 already programmed — skipping."
else
    echo ""
    echo "  This will program YubiKey slot 2 with HMAC-SHA1 (long-press)."
    echo "  Press Enter to continue or Ctrl-C to abort."
    read -r
    ykman otp chalresp --generate 2 --touch --force 2>&1
    log "  HMAC-SHA1 programmed on slot 2."
fi

# ══════════════════════════════════════════════════════════════
# Phase 4: Mount external drive and create vault directory
# ══════════════════════════════════════════════════════════════
log "Phase 4: External storage"

if [ -z "$VAULT_DIR" ]; then
    # Auto-detect: mount Transcend
    if [ -b "$TRANSCEND_DEV" ]; then
        if ! mountpoint -q "$TRANSCEND_MNT" 2>/dev/null; then
            "$SUDO_WRAP" mkdir -p "$TRANSCEND_MNT"
            "$SUDO_WRAP" mount -t ntfs-3g "$TRANSCEND_DEV" "$TRANSCEND_MNT"
            log "  Mounted Transcend at $TRANSCEND_MNT"
        else
            log "  Transcend already mounted at $TRANSCEND_MNT"
        fi
        VAULT_DIR="$TRANSCEND_MNT/peridot-vault"
    else
        die "No --vault-dir specified and Transcend ($TRANSCEND_DEV) not found."
    fi
fi

mkdir -p "$VAULT_DIR"
log "  Vault directory: $VAULT_DIR"

# ══════════════════════════════════════════════════════════════
# Phase 5: Create LUKS container
# ══════════════════════════════════════════════════════════════
log "Phase 5: LUKS container"

VAULT_PATH="$VAULT_DIR/$VAULT_FILE"

if [ -f "$VAULT_PATH" ]; then
    log "  vault.luks already exists — skipping creation."
    log "  To recreate, delete $VAULT_PATH and re-run."
else
    # Generate HMAC challenge and derive LUKS passphrase
    CHALLENGE=$(openssl rand -hex 32)
    log "  Touch YubiKey NOW (long press, slot 2)..."
    LUKS_PASS=$(ykchalresp -2 "$CHALLENGE" 2>/dev/null)
    [ -z "$LUKS_PASS" ] && die "HMAC response failed — did you touch the key?"

    # Store challenge
    mkdir -p "$CRED_DIR"
    echo "$CHALLENGE" > "$CRED_DIR/luks-challenge.txt"
    chmod 600 "$CRED_DIR/luks-challenge.txt"

    # Create container file
    log "  Creating ${VAULT_SIZE_MB}MB container..."
    dd if=/dev/zero of="$VAULT_PATH" bs=1M count="$VAULT_SIZE_MB" 2>/dev/null

    # Format as LUKS2
    log "  Formatting as LUKS2..."
    printf '%s' "$LUKS_PASS" | "$SUDO_WRAP" cryptsetup luksFormat \
        --type luks2 --cipher aes-xts-plain64 --key-size 512 \
        --hash sha512 --iter-time 3000 --batch-mode \
        "$VAULT_PATH" -

    # Open and format ext4 inside
    printf '%s' "$LUKS_PASS" | "$SUDO_WRAP" cryptsetup open \
        --type luks2 "$VAULT_PATH" "$LUKS_NAME" -

    "$SUDO_WRAP" mkfs.ext4 -L "PERIDOT-KEYS" "/dev/mapper/$LUKS_NAME" >/dev/null 2>&1

    unset LUKS_PASS
    log "  LUKS container created and formatted."
fi

# ══════════════════════════════════════════════════════════════
# Phase 6: Export GPG keys into the container
# ══════════════════════════════════════════════════════════════
log "Phase 6: GPG key export"

# Check if private keys exist locally
if ! gpg --list-secret-keys 2>/dev/null | grep -q sec; then
    log "  No private keys on disk — already moved or export not needed."
    # Close LUKS if open
    "$SUDO_WRAP" cryptsetup close "$LUKS_NAME" 2>/dev/null || true
else
    # Open LUKS if not already open
    if [ ! -b "/dev/mapper/$LUKS_NAME" ]; then
        CHALLENGE=$(cat "$CRED_DIR/luks-challenge.txt")
        log "  Touch YubiKey NOW to open vault..."
        LUKS_PASS=$(ykchalresp -2 "$CHALLENGE" 2>/dev/null)
        [ -z "$LUKS_PASS" ] && die "HMAC failed"
        printf '%s' "$LUKS_PASS" | "$SUDO_WRAP" cryptsetup open \
            --type luks2 "$VAULT_PATH" "$LUKS_NAME" -
        unset LUKS_PASS
    fi

    "$SUDO_WRAP" mkdir -p "$MOUNT_POINT"
    "$SUDO_WRAP" mount "/dev/mapper/$LUKS_NAME" "$MOUNT_POINT"
    "$SUDO_WRAP" chown "$(id -u):$(id -g)" "$MOUNT_POINT"

    mkdir -p "$MOUNT_POINT/$EXPORT_DIR"
    chmod 700 "$MOUNT_POINT/$EXPORT_DIR"

    gpg --export-secret-keys --armor > "$MOUNT_POINT/$EXPORT_DIR/secring.gpg"
    gpg --export --armor > "$MOUNT_POINT/$EXPORT_DIR/pubring.gpg"
    gpg --export-ownertrust > "$MOUNT_POINT/$EXPORT_DIR/ownertrust.txt"
    chmod 600 "$MOUNT_POINT/$EXPORT_DIR"/*

    log "  Exported: secring.gpg, pubring.gpg, ownertrust.txt"

    # Close
    "$SUDO_WRAP" umount "$MOUNT_POINT"
    "$SUDO_WRAP" cryptsetup close "$LUKS_NAME"

    # ══════════════════════════════════════════════════════════
    # Phase 7: Delete private keys from local disk
    # ══════════════════════════════════════════════════════════
    log "Phase 7: Removing private keys from disk"

    # Shred the key files
    for kf in "$GNUPG_DIR"/private-keys-v1.d/*.key; do
        [ -f "$kf" ] || continue
        dd if=/dev/urandom of="$kf" bs=$(stat -c%s "$kf") count=1 conv=notrunc 2>/dev/null
        rm -f "$kf"
        log "  Shredded $(basename "$kf")"
    done

    # Delete secret keys from GPG keyring
    GPG_FPR=$(gpg --list-secret-keys --with-colons 2>/dev/null \
        | awk -F: '/^fpr:/{print $10; exit}')
    if [ -n "$GPG_FPR" ]; then
        gpg --batch --yes --delete-secret-keys "$GPG_FPR" 2>/dev/null || true
    fi

    # Verify
    if gpg --list-secret-keys 2>/dev/null | grep -q sec; then
        log "  WARNING: Private keys still detected — manual removal may be needed"
    else
        log "  Private keys removed from disk."
    fi
fi

# ══════════════════════════════════════════════════════════════
# Phase 8: Store vault metadata
# ══════════════════════════════════════════════════════════════
log "Phase 8: Metadata"

echo "$VAULT_PATH" > "$CRED_DIR/vault-path.txt"
chmod 600 "$CRED_DIR/vault-path.txt"

# Write README inside vault dir (unencrypted, human-readable)
cat > "$VAULT_DIR/README.txt" << 'README'
PERIDOT KEY VAULT
=================

This directory contains a LUKS2-encrypted container (vault.luks) holding
GPG private keys for the Peridot agent (peridot@mx.local).

To use:
  1. Copy this entire directory to any USB storage
  2. Update ~/.openclaw/credentials/vault-path.txt with the new path
  3. Run: key-release <command>
     - Requires YubiKey with HMAC-SHA1 on slot 2 (long press)

Security:
  - LUKS passphrase is derived from YubiKey HMAC-SHA1 challenge-response
  - The challenge is stored at ~/.openclaw/credentials/luks-challenge.txt
  - The challenge alone is useless without the physical YubiKey
  - Private keys are never stored unencrypted on any disk
  - During use, keys exist only in RAM (/dev/shm, tmpfs)

To re-setup on a new machine:
  1. Install: pcscd, yubikey-manager, yubikey-personalization, cryptsetup, pass
  2. Copy this directory to the new machine's external storage
  3. Copy ~/.openclaw/credentials/{luks-challenge.txt,vault-path.txt} to the new machine
  4. Run: key-release --status
README

log "  Vault path: $VAULT_PATH"
log "  Challenge:  $CRED_DIR/luks-challenge.txt"

# ══════════════════════════════════════════════════════════════
# Phase 9: Create key-release, key-lock, update sudo-wrap
# ══════════════════════════════════════════════════════════════
log "Phase 9: Creating scripts"

mkdir -p "$(dirname "$KEY_RELEASE")"

# ── key-release ───────────────────────────────────────────────
cat > "$KEY_RELEASE" << 'RELEASE'
#!/bin/bash
# key-release — YubiKey-gated GPG key release from encrypted vault.
#
# Per-operation (default): key-release <command> [args...]
#   Unlocks keys, runs command, wipes keys immediately.
#
# Hold mode: key-release --hold [--ttl <minutes>]
#   Unlocks keys and holds them in RAM for batch operations.
#   TTL tiers (based on privilege level):
#     --ttl 1   (root/chpasswd/firewall — highest privilege)
#     --ttl 3   (sudo — elevated privilege)
#     --ttl 5   (pass decrypt — standard, default for --hold)
#
# Status: key-release --status
# Lock:   key-lock

set -uo pipefail

CRED_DIR="$HOME/.openclaw/credentials"
LIVE_GNUPG="/dev/shm/.gnupg-live"
LUKS_NAME="peridot-keys"
MOUNT_POINT="/mnt/$LUKS_NAME"
EXPORT_DIR="gnupg-export"
GNUPG_ORIG="$HOME/.gnupg"
ENV_FILE="$HOME/.gnupg-live-env"
LOCK_PID_FILE="/tmp/.key-release-lock.pid"

err() { echo "[key-release] $*" >&2; }

# ── Parse args ────────────────────────────────────────────────
MODE="exec"  # exec (default) | hold | status
TTL=5
CMD=()

while [ $# -gt 0 ]; do
    case "$1" in
        --status)
            if [ -d "$LIVE_GNUPG" ] && \
               gpg --homedir "$LIVE_GNUPG" --list-secret-keys 2>/dev/null | grep -q sec; then
                echo "UNLOCKED (GNUPGHOME=$LIVE_GNUPG)"
                [ -f "$LOCK_PID_FILE" ] && echo "Auto-lock PID: $(cat "$LOCK_PID_FILE")"
            else
                echo "LOCKED"
            fi
            exit 0
            ;;
        --hold) MODE="hold" ;;
        --ttl)  shift; TTL="${1:-5}" ;;
        --)     shift; CMD=("$@"); break ;;
        -*)     err "Unknown flag: $1"; exit 1 ;;
        *)      CMD=("$@"); break ;;
    esac
    shift
done

# ── Already unlocked? ────────────────────────────────────────
if [ -d "$LIVE_GNUPG" ] && \
   gpg --homedir "$LIVE_GNUPG" --list-secret-keys 2>/dev/null | grep -q sec; then
    if [ "$MODE" = "exec" ] && [ ${#CMD[@]} -gt 0 ]; then
        GNUPGHOME="$LIVE_GNUPG" "${CMD[@]}"
        exit $?
    elif [ "$MODE" = "hold" ]; then
        echo "[key-release] Already unlocked."
        exit 0
    fi
fi

# ── Step 1: Detect YubiKey ───────────────────────────────────
if ! command -v ykchalresp >/dev/null 2>&1; then
    err "ykchalresp not found. Install: sudo apt install yubikey-personalization"
    exit 1
fi

if ! lsusb 2>/dev/null | grep -qi "1050:"; then
    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║  Plug in your YubiKey and press Enter.    ║"
    echo "╚═══════════════════════════════════════════╝"
    read -r
    sleep 1
    lsusb 2>/dev/null | grep -qi "1050:" || { err "YubiKey not detected."; exit 1; }
fi

# ── Step 2: HMAC challenge-response ──────────────────────────
CHALLENGE=$(cat "$CRED_DIR/luks-challenge.txt" 2>/dev/null)
[ -z "$CHALLENGE" ] && { err "No LUKS challenge at $CRED_DIR/luks-challenge.txt"; exit 1; }

echo "[key-release] Touch YubiKey NOW (long press, slot 2)..."
LUKS_PASS=$(ykchalresp -2 "$CHALLENGE" 2>/dev/null)
[ -z "$LUKS_PASS" ] && { err "HMAC failed — touch the key when it blinks."; exit 1; }

# ── Step 3: Open LUKS vault ──────────────────────────────────
VAULT_PATH=$(cat "$CRED_DIR/vault-path.txt" 2>/dev/null)
[ -z "$VAULT_PATH" ] && { err "No vault path at $CRED_DIR/vault-path.txt"; exit 1; }

if [ ! -f "$VAULT_PATH" ]; then
    err "Vault not found at $VAULT_PATH — is the USB drive mounted?"
    exit 1
fi

# Use sudo-wrap's cached cred or fall back
if ! sudo -n true 2>/dev/null; then
    printf '%s\n' "$LUKS_PASS" | sudo -S true 2>/dev/null || true
fi

if [ ! -b "/dev/mapper/$LUKS_NAME" ]; then
    printf '%s' "$LUKS_PASS" | sudo cryptsetup open \
        --type luks2 "$VAULT_PATH" "$LUKS_NAME" - 2>/dev/null
fi
unset LUKS_PASS

sudo mkdir -p "$MOUNT_POINT"
sudo mount "/dev/mapper/$LUKS_NAME" "$MOUNT_POINT" 2>/dev/null

# ── Step 4: Import keys to tmpfs ─────────────────────────────
rm -rf "$LIVE_GNUPG"
mkdir -p "$LIVE_GNUPG"
chmod 700 "$LIVE_GNUPG"

# Copy public keyring and trust from original
cp "$GNUPG_ORIG/pubring.kbx" "$LIVE_GNUPG/" 2>/dev/null || true
cp "$GNUPG_ORIG/trustdb.gpg" "$LIVE_GNUPG/" 2>/dev/null || true

# Import secret keys from vault
gpg --homedir "$LIVE_GNUPG" --batch --import \
    "$MOUNT_POINT/$EXPORT_DIR/secring.gpg" 2>/dev/null
gpg --homedir "$LIVE_GNUPG" --import-ownertrust \
    "$MOUNT_POINT/$EXPORT_DIR/ownertrust.txt" 2>/dev/null

# ── Step 5: Close vault immediately ──────────────────────────
sudo umount "$MOUNT_POINT" 2>/dev/null
sudo cryptsetup close "$LUKS_NAME" 2>/dev/null
echo "[key-release] Keys loaded to RAM. Vault closed."

# ── Step 6: Execute or hold ──────────────────────────────────
export GNUPGHOME="$LIVE_GNUPG"
echo "export GNUPGHOME=$LIVE_GNUPG" > "$ENV_FILE"

if [ "$MODE" = "exec" ] && [ ${#CMD[@]} -gt 0 ]; then
    # Per-operation: run, then wipe
    "${CMD[@]}"
    RET=$?
    "$HOME/.local/bin/key-lock" 2>/dev/null
    exit $RET
elif [ "$MODE" = "hold" ]; then
    # Hold mode with TTL
    (
        sleep $(( TTL * 60 ))
        "$HOME/.local/bin/key-lock" 2>/dev/null
    ) &
    LOCK_PID=$!
    echo "$LOCK_PID" > "$LOCK_PID_FILE"
    disown "$LOCK_PID" 2>/dev/null
    echo "[key-release] Holding for ${TTL} minutes (PID $LOCK_PID)."
    echo "[key-release] source $ENV_FILE  # to use in this shell"
else
    # No command given in exec mode — treat as hold with 1-min TTL
    (
        sleep 60
        "$HOME/.local/bin/key-lock" 2>/dev/null
    ) &
    echo "$!" > "$LOCK_PID_FILE"
    disown 2>/dev/null
    echo "[key-release] Unlocked for 1 minute. Run key-lock to close early."
fi
RELEASE

chmod 700 "$KEY_RELEASE"
log "  Created $KEY_RELEASE"

# ── key-lock ──────────────────────────────────────────────────
cat > "$KEY_LOCK" << 'LOCK'
#!/bin/bash
# key-lock — Wipe GPG keys from RAM.

LIVE_GNUPG="/dev/shm/.gnupg-live"
LOCK_PID_FILE="/tmp/.key-release-lock.pid"
ENV_FILE="$HOME/.gnupg-live-env"

if [ -d "$LIVE_GNUPG" ]; then
    find "$LIVE_GNUPG" -type f -exec sh -c \
        'dd if=/dev/urandom of="$1" bs=$(stat -c%s "$1") count=1 conv=notrunc 2>/dev/null' _ {} \;
    rm -rf "$LIVE_GNUPG"
    echo "[key-lock] Keys wiped from RAM."
else
    echo "[key-lock] Already locked."
fi

[ -f "$LOCK_PID_FILE" ] && kill "$(cat "$LOCK_PID_FILE")" 2>/dev/null
rm -f "$LOCK_PID_FILE"
echo "# locked" > "$ENV_FILE"
unset GNUPGHOME
LOCK

chmod 700 "$KEY_LOCK"
log "  Created $KEY_LOCK"

# ── sudo-wrap (updated) ──────────────────────────────────────
cat > "$SUDO_WRAP" << 'WRAP'
#!/bin/bash
# sudo-wrap — YubiKey-gated sudo via pass-stored credentials.
#
# If keys are unlocked: uses pass directly.
# If keys are locked:   calls key-release for per-operation unlock.
#
# TTL tier for sudo operations: 3 minutes (elevated privilege).

if [ $# -eq 0 ]; then
    echo "Usage: sudo-wrap <command> [args...]" >&2; exit 1
fi

# Source GNUPGHOME if released
[ -f "$HOME/.gnupg-live-env" ] && source "$HOME/.gnupg-live-env"

# If sudo cached, skip everything
if sudo -n true 2>/dev/null; then
    exec sudo "$@"
fi

# Check if keys are in RAM
LIVE_GNUPG="/dev/shm/.gnupg-live"
if [ -d "$LIVE_GNUPG" ] && \
   gpg --homedir "$LIVE_GNUPG" --list-secret-keys 2>/dev/null | grep -q sec; then
    # Keys available — use pass directly
    PW=$(GNUPGHOME="$LIVE_GNUPG" pass show mx/user 2>/dev/null | head -1)
    printf '%s\n' "$PW" | sudo -S "$@" 2>&1 | grep -v '^\[sudo\] password'
    RET=${PIPESTATUS[1]}
    unset PW
    exit "$RET"
fi

# Keys locked — per-operation release via YubiKey
echo "[sudo-wrap] Keys locked. Requesting YubiKey release..."
exec "$HOME/.local/bin/key-release" sudo "$@"
WRAP

chmod 700 "$SUDO_WRAP"
log "  Updated $SUDO_WRAP"

# ══════════════════════════════════════════════════════════════
# Phase 10: Unmount external drive
# ══════════════════════════════════════════════════════════════
if mountpoint -q "$TRANSCEND_MNT" 2>/dev/null; then
    "$SUDO_WRAP" umount "$TRANSCEND_MNT" 2>/dev/null || true
    log "  Unmounted $TRANSCEND_MNT"
fi

# ══════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════
log ""
log "═════════════════════════════════════════════════════════"
log " VAULT SETUP COMPLETE"
log "═════════════════════════════════════════════════════════"
log ""
log " Vault:     $VAULT_PATH"
log " Challenge: $CRED_DIR/luks-challenge.txt"
log " GPG keys:  REMOVED from local disk"
log ""
log " TTL Tiers (for --hold mode):"
log "   --ttl 1   root/chpasswd/firewall (highest privilege)"
log "   --ttl 3   sudo operations (elevated)"
log "   --ttl 5   pass decrypt (standard, default)"
log ""
log " Usage:"
log "   key-release <cmd>          per-operation (unlock, run, wipe)"
log "   key-release --hold         hold 5 min (standard)"
log "   key-release --hold --ttl 1 hold 1 min (high privilege)"
log "   key-lock                   manual wipe"
log "   key-release --status       check state"
log "   sudo-wrap <cmd>            auto-gates via YubiKey"
log ""
log " To move vault to USB thumb drive:"
log "   1. Copy $VAULT_DIR to the thumb drive"
log "   2. Update $CRED_DIR/vault-path.txt with the new path"
log ""
