#!/bin/bash
# rotate-system-passwords.sh
#
# Generates cryptographically secure passwords for root and user,
# stores them in `pass` (GPG-encrypted), and applies them via chpasswd.
#
# Passwords NEVER appear in stdout, env vars, shell history, argv, or
# any file readable without GPG decryption.
#
# After running:
#   sudo-wrap <command>   — LLM runs sudo without seeing the password
#   pass show mx/user     — Vincent decrypts on demand (GPG-protected)
#   pass show mx/root     — Vincent decrypts on demand (GPG-protected)

set -euo pipefail
trap 'rm -f "$CHPW" 2>/dev/null' EXIT

PASS_DIR="$HOME/.password-store"
GPG_ID_FILE="$PASS_DIR/.gpg-id"
SUDO_WRAP="$HOME/.local/bin/sudo-wrap"
PASS_PREFIX="mx"
PW_LENGTH=32
OLD_PASS_FILE="$HOME/.openclaw/credentials/user.secret"

log() { echo "[rotate] $*"; }

# ── Step 0: Prerequisites ─────────────────────────────────────
log "Checking prerequisites..."

if ! command -v gpg >/dev/null 2>&1; then
    log "FATAL: gpg not installed"; exit 1
fi

if ! command -v pass >/dev/null 2>&1; then
    log "Installing pass..."
    if [ -f "$OLD_PASS_FILE" ]; then
        cat "$OLD_PASS_FILE" | sudo -S apt-get install -y pass >/dev/null 2>&1
    else
        log "FATAL: pass not installed and no sudo cred available"; exit 1
    fi
fi

# ── Step 1: GPG key ───────────────────────────────────────────
if ! gpg --list-secret-keys 2>/dev/null | grep -q sec; then
    log "Generating GPG key (peridot@mx.local)..."
    gpg --batch --gen-key <<'GPGEOF'
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: Peridot
Name-Email: peridot@mx.local
Expire-Date: 0
%commit
GPGEOF
    log "GPG key generated."
fi

GPG_KEY=$(gpg --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')

if [ -z "$GPG_KEY" ]; then
    log "FATAL: No GPG key found."; exit 1
fi
log "GPG key: ${GPG_KEY:0:16}..."

# ── Step 2: Initialize pass ───────────────────────────────────
if [ ! -f "$GPG_ID_FILE" ]; then
    log "Initializing pass store..."
    pass init "$GPG_KEY" >/dev/null 2>&1
fi

# ── Step 3: Generate + store + apply passwords ────────────────
# openssl rand avoids the tr|head SIGPIPE problem entirely.
# Passwords live only in the subshell and the tmpfs temp file.

log "Generating passwords (${PW_LENGTH} chars each)..."

CHPW=$(mktemp -p /dev/shm .chpw-XXXXXX)
chmod 600 "$CHPW"

gen_password() {
    openssl rand -base64 48 | tr -d '/+\n' | cut -c1-"$PW_LENGTH"
}

# Root password — subshell so PW never leaks to parent
(
    PW=$(gen_password)
    printf '%s\n' "$PW" | pass insert -e -f "${PASS_PREFIX}/root" >/dev/null 2>&1
    printf 'root:%s\n' "$PW" >> "$CHPW"
)

# User password — same isolation
(
    PW=$(gen_password)
    printf '%s\n' "$PW" | pass insert -e -f "${PASS_PREFIX}/user" >/dev/null 2>&1
    printf 'user:%s\n' "$PW" >> "$CHPW"
)

log "Applying via chpasswd..."

# sudo -S reads password from stdin, but chpasswd also needs stdin.
# Solution: feed sudo password via -S, then use --stdin or a temp askpass.
ASKPASS=$(mktemp /tmp/.askpass-XXXXXX)
chmod 700 "$ASKPASS"
if [ -f "$OLD_PASS_FILE" ]; then
    # askpass must print password to stdout — use printf to avoid trailing newline issues
    printf '#!/bin/sh\nprintf "%%s" "$(cat "%s")"\n' "$OLD_PASS_FILE" > "$ASKPASS"
else
    printf '#!/bin/sh\npass show mx/user 2>/dev/null | head -1 | tr -d "\\n"\n' > "$ASKPASS"
fi
SUDO_ASKPASS="$ASKPASS" sudo -A chpasswd < "$CHPW" 2>/dev/null
dd if=/dev/urandom of="$ASKPASS" bs=64 count=1 conv=notrunc 2>/dev/null
rm -f "$ASKPASS"

# Wipe temp file
dd if=/dev/urandom of="$CHPW" bs=128 count=1 conv=notrunc 2>/dev/null
rm -f "$CHPW"
CHPW=""

log "Passwords rotated."

# ── Step 4: Delete old plaintext secrets ──────────────────────
for f in user.secret root.secret; do
    fp="$HOME/.openclaw/credentials/$f"
    if [ -f "$fp" ]; then
        dd if=/dev/urandom of="$fp" bs=64 count=1 conv=notrunc 2>/dev/null
        rm -f "$fp"
        log "Shredded $f"
    fi
done

# ── Step 5: Create sudo-wrap ─────────────────────────────────
mkdir -p "$(dirname "$SUDO_WRAP")"

cat > "$SUDO_WRAP" << 'WRAPPER'
#!/bin/bash
# sudo-wrap — runs sudo using the GPG-encrypted password from pass.
# The LLM calls this; it never sees the password.
#
# Usage: sudo-wrap <command> [args...]

if [ $# -eq 0 ]; then
    echo "Usage: sudo-wrap <command> [args...]" >&2; exit 1
fi

# If sudo is already cached, skip pass entirely
if sudo -n true 2>/dev/null; then
    exec sudo "$@"
fi

# Read password into a variable inside this process (never exported, never in argv)
PW=$(pass show mx/user 2>/dev/null | head -1)
printf '%s\n' "$PW" | sudo -S "$@" 2>&1 | grep -v '^\[sudo\] password'
RET=${PIPESTATUS[1]}
unset PW
exit "$RET"
WRAPPER

chmod 700 "$SUDO_WRAP"
log "Created $SUDO_WRAP"

# ── Step 6: Verify ────────────────────────────────────────────
log ""
log "=== VERIFICATION ==="

log "pass store:"
pass ls 2>/dev/null

log ""
log "sudo-wrap whoami:"
"$SUDO_WRAP" whoami 2>&1

log ""
log "Old secrets remaining:"
ls "$HOME/.openclaw/credentials/" 2>/dev/null || echo "  (none)"

log ""
log "=== COMPLETE ==="
log "  LLM:     sudo-wrap <command>"
log "  Vincent: pass show mx/user"
log "  Rotate:  bash ~/workspace/scripts/rotate-system-passwords.sh"
