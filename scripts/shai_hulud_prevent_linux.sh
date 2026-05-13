#!/bin/bash
# Workspace ONE Script: Mini Shai-Hulud PREVENTION (Linux)
# Script name: shai_hulud_prevent
# Execution Context: System (required for /etc/hosts and /etc/npmrc)
#
# Tested on: Ubuntu 22.04/24.04, RHEL 9, Debian 12.
# For other distros, the immutable-flag and user-enumeration paths may need adjusting.

set +e

LOG_DIR="/var/log/omnissa/shai_hulud"
LOG_FILE="$LOG_DIR/prevent.log"
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG_FILE"
}

log "=== shai_hulud_prevent starting ==="

# ---------------------------------------------------------------------------
# 1. /etc/npmrc: ignore-scripts = true
# ---------------------------------------------------------------------------
cat > /etc/npmrc <<'EOF'
; Managed by Omnissa Workspace ONE - shai_hulud_prevent
; Disables npm/pnpm/yarn lifecycle scripts to block supply-chain droppers.
; Per-package override: npm install --foreground-scripts <pkg>
ignore-scripts=true
fund=false
audit-level=high
EOF
chmod 644 /etc/npmrc
log "Wrote /etc/npmrc"

mkdir -p /etc/pnpm
cat > /etc/pnpm/rc <<'EOF'
ignore-scripts=true
side-effects-cache=false
EOF
chmod 644 /etc/pnpm/rc
log "Wrote /etc/pnpm/rc"

# Shell env: cover bash and zsh. /etc/profile is read by both.
START_MARK="# BEGIN shai_hulud_prevent (Omnissa)"
END_MARK="# END shai_hulud_prevent"

apply_shell_env() {
    local file="$1"
    [ ! -e "$file" ] && touch "$file"
    # Strip previous managed block
    sed -i "/$START_MARK/,/$END_MARK/d" "$file"
    cat >> "$file" <<EOF
$START_MARK
export YARN_ENABLE_SCRIPTS=false
export npm_config_ignore_scripts=true
$END_MARK
EOF
    log "Updated shell env: $file"
}

apply_shell_env /etc/profile
[ -f /etc/bash.bashrc ] && apply_shell_env /etc/bash.bashrc
[ -d /etc/zsh ] && apply_shell_env /etc/zsh/zshenv

# ---------------------------------------------------------------------------
# 2. /etc/hosts: block known C2 / payload-fetch domains
# ---------------------------------------------------------------------------
HOSTS_FILE="/etc/hosts"
[ ! -f "$HOSTS_FILE.omnissa.bak" ] && cp "$HOSTS_FILE" "$HOSTS_FILE.omnissa.bak"

sed -i "/$START_MARK/,/$END_MARK/d" "$HOSTS_FILE"

cat >> "$HOSTS_FILE" <<EOF
$START_MARK
0.0.0.0	git-tanstack.com
0.0.0.0	www.git-tanstack.com
0.0.0.0	api.cloud-aws.adc-e.uk
0.0.0.0	filev2.getsession.org
0.0.0.0	seed1.getsession.org
0.0.0.0	seed2.getsession.org
0.0.0.0	seed3.getsession.org
0.0.0.0	api.masscan.cloud
0.0.0.0	83.142.209.194
$END_MARK
EOF

# Flush systemd-resolved cache if present
if command -v systemd-resolve >/dev/null 2>&1; then
    systemd-resolve --flush-caches 2>/dev/null
elif command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches 2>/dev/null
fi
# nscd if used
command -v nscd >/dev/null 2>&1 && nscd -i hosts 2>/dev/null

log "Updated /etc/hosts; flushed DNS cache"

# ---------------------------------------------------------------------------
# 3. Tripwire files at persistence paths for every real user
#    UID >= 1000 on most distros; some distros (RHEL) use 500. We accept >= 500.
# ---------------------------------------------------------------------------
TRIPWIRE_FILES="setup.mjs setup.sh router_runtime.js router_init.js execution.js tanstack_runner.js opensearch_init.js"
TRIPWIRE_SUBDIRS=".claude .vscode"

# chattr availability check (not present on all minimal containers)
HAVE_CHATTR=0
command -v chattr >/dev/null 2>&1 && HAVE_CHATTR=1

while IFS=: read -r username _ uid _ _ home shell; do
    [ "$uid" -lt 500 ] && continue
    [ ! -d "$home" ] && continue
    # Skip service accounts and nobody-style accounts
    case "$shell" in
        */nologin|/bin/false|"") continue ;;
    esac

    user_group=$(id -gn "$username" 2>/dev/null || echo "$username")

    for sub in $TRIPWIRE_SUBDIRS; do
        sub_path="$home/$sub"
        if [ ! -d "$sub_path" ]; then
            mkdir -p "$sub_path" 2>/dev/null
            chown "$username:$user_group" "$sub_path" 2>/dev/null
            chmod 755 "$sub_path" 2>/dev/null
        fi
        for fn in $TRIPWIRE_FILES; do
            trip="$sub_path/$fn"
            if [ ! -f "$trip" ]; then
                echo "# Workspace ONE tripwire - do not delete" > "$trip"
                chown root:root "$trip"
                chmod 444 "$trip"
                # ext4/xfs/btrfs immutable flag; will silently no-op on filesystems that don't support it (tmpfs, etc)
                [ "$HAVE_CHATTR" -eq 1 ] && chattr +i "$trip" 2>/dev/null
                log "Tripwire placed: $trip"
            fi
        done
    done
done < <(getent passwd)

# ---------------------------------------------------------------------------
# 4. Marker file
# ---------------------------------------------------------------------------
mkdir -p /var/lib/omnissa
cat > /var/lib/omnissa/shai_hulud_prevent.state <<EOF
LastRun=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
Version=1.0
EOF

log "=== shai_hulud_prevent complete ==="
echo "shai_hulud_prevent: OK"
