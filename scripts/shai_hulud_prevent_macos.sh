#!/bin/bash
# Workspace ONE Script: Mini Shai-Hulud / TanStack PREVENTION (macOS)
# Script name: shai_hulud_prevent
# Execution Context: System (required for /etc/hosts and /etc/npmrc)
#
# Purpose: Pre-emptively block the persistence and propagation vectors of the
# Mini Shai-Hulud / TanStack supply chain worm.
#
# What it does:
#   1. Sets ignore-scripts=true in /etc/npmrc (machine-wide npm) and yarn/pnpm equivalents
#   2. Adds known C2 domains to /etc/hosts
#   3. Drops read-only tripwire files at common persistence paths in each user's home
#   4. Logs to /Library/Application Support/Omnissa/shai_hulud/prevent.log

set +e

LOG_DIR="/Library/Application Support/Omnissa/shai_hulud"
LOG_FILE="$LOG_DIR/prevent.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG_FILE"
}

log "=== shai_hulud_prevent starting ==="

# ---------------------------------------------------------------------------
# 1. /etc/npmrc: ignore-scripts = true (kills preinstall hook propagation)
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
log "Wrote /etc/npmrc with ignore-scripts=true"

# pnpm global config
mkdir -p /etc/pnpm
cat > /etc/pnpm/rc <<'EOF'
ignore-scripts=true
side-effects-cache=false
EOF
chmod 644 /etc/pnpm/rc
log "Wrote /etc/pnpm/rc"

# Yarn: machine-wide env via /etc/zshenv (picked up by all interactive zsh shells)
# We tag the block so we can re-write idempotently
ENV_FILE="/etc/zshenv"
START_MARK="# BEGIN shai_hulud_prevent (Omnissa)"
END_MARK="# END shai_hulud_prevent"
if [ -f "$ENV_FILE" ]; then
    # Strip previous managed block
    sed -i '' "/$START_MARK/,/$END_MARK/d" "$ENV_FILE"
fi
cat >> "$ENV_FILE" <<EOF
$START_MARK
export YARN_ENABLE_SCRIPTS=false
export npm_config_ignore_scripts=true
$END_MARK
EOF
log "Updated $ENV_FILE with YARN_ENABLE_SCRIPTS=false"

# bash users: same in /etc/bashrc
BASH_FILE="/etc/bashrc"
if [ -f "$BASH_FILE" ]; then
    sed -i '' "/$START_MARK/,/$END_MARK/d" "$BASH_FILE"
fi
cat >> "$BASH_FILE" <<EOF
$START_MARK
export YARN_ENABLE_SCRIPTS=false
export npm_config_ignore_scripts=true
$END_MARK
EOF
log "Updated $BASH_FILE"

# ---------------------------------------------------------------------------
# 2. /etc/hosts: block known C2 / payload-fetch domains
#    Note: Session/Oxen exfil bypasses DNS, so this is partial coverage only.
# ---------------------------------------------------------------------------
HOSTS_FILE="/etc/hosts"
# Backup first
[ ! -f "$HOSTS_FILE.omnissa.bak" ] && cp "$HOSTS_FILE" "$HOSTS_FILE.omnissa.bak"

# Strip previous managed block
sed -i '' "/$START_MARK/,/$END_MARK/d" "$HOSTS_FILE"

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

# Flush DNS cache so changes take effect immediately
dscacheutil -flushcache 2>/dev/null
killall -HUP mDNSResponder 2>/dev/null
log "Updated /etc/hosts with C2 blocks; flushed DNS cache"

# ---------------------------------------------------------------------------
# 3. Tripwire files at known persistence paths in each user's home
# ---------------------------------------------------------------------------
TRIPWIRE_FILES="setup.mjs setup.sh router_runtime.js router_init.js execution.js tanstack_runner.js opensearch_init.js"
TRIPWIRE_SUBDIRS=".claude .vscode"

# Iterate real user accounts (UID >= 500, has shell, has home under /Users)
while IFS=: read -r username _ uid _ _ home shell; do
    [ "$uid" -lt 500 ] && continue
    [ ! -d "$home" ] && continue
    case "$home" in /Users/*) ;; *) continue ;; esac

    for sub in $TRIPWIRE_SUBDIRS; do
        sub_path="$home/$sub"
        if [ ! -d "$sub_path" ]; then
            mkdir -p "$sub_path" 2>/dev/null
            chown "$username":staff "$sub_path" 2>/dev/null
        fi
        for fn in $TRIPWIRE_FILES; do
            trip="$sub_path/$fn"
            if [ ! -f "$trip" ]; then
                echo "# Workspace ONE tripwire - do not delete" > "$trip"
                chown root:wheel "$trip"
                chmod 444 "$trip"
                # macOS user immutable flag - belt and braces
                chflags uchg "$trip" 2>/dev/null
                log "Tripwire placed: $trip"
            fi
        done
    done
done < <(dscl . -list /Users UniqueID | awk '{print $1":x:"$2":20:User:/Users/"$1":/bin/zsh"}' | grep -v '^_')

# ---------------------------------------------------------------------------
# 4. Marker for sensor
# ---------------------------------------------------------------------------
defaults write /Library/Preferences/com.omnissa.shai_hulud_prevent LastRun "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
defaults write /Library/Preferences/com.omnissa.shai_hulud_prevent Version "1.0"

log "=== shai_hulud_prevent complete ==="
echo "shai_hulud_prevent: OK"
