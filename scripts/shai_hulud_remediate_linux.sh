#!/bin/bash
# Workspace ONE Script: Mini Shai-Hulud REMEDIATION (Linux)
# Script name: shai_hulud_remediate
# Execution Context: System
#
# CRITICAL ORDERING: Disable the gh-token-monitor systemd user unit FIRST.
# The worm polls every 60 seconds and triggers `rm -rf ~/` on HTTP 40x.

set +e

LOG_DIR="/var/log/omnissa/shai_hulud"
TS=$(date '+%Y%m%d_%H%M%S')
QUAR_DIR="$LOG_DIR/quarantine/$TS"
LOG_FILE="$LOG_DIR/remediate.log"
mkdir -p "$QUAR_DIR"
chmod 750 "$QUAR_DIR"

ACTIONS=""

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG_FILE"
}

add_action() {
    ACTIONS="${ACTIONS}${ACTIONS:+;}$1"
}

quarantine_file() {
    local path="$1"
    [ ! -e "$path" ] && return 1
    # Strip immutable flag in case it's a tripwire we placed
    command -v chattr >/dev/null 2>&1 && chattr -i "$path" 2>/dev/null
    local safe
    safe=$(echo "$path" | sed 's|/|_|g' | sed 's|^_||')
    if mv "$path" "$QUAR_DIR/$safe" 2>/dev/null; then
        log "Quarantined: $path -> $QUAR_DIR/$safe"
        add_action "QUARANTINED:$path"
        return 0
    else
        log "QUARANTINE FAILED: $path"
        add_action "QUARANTINE_FAIL:$path"
        return 1
    fi
}

log "=== shai_hulud_remediate starting (quarantine=$QUAR_DIR) ==="

# ---------------------------------------------------------------------------
# STEP 1 - HIGHEST PRIORITY: kill the dead-man's switch.
# ---------------------------------------------------------------------------
log "Step 1: Disable gh-token-monitor (HIGHEST PRIORITY)"

while IFS=: read -r username _ uid _ _ home shell; do
    [ "$uid" -lt 500 ] && continue
    [ ! -d "$home" ] && continue
    case "$shell" in
        */nologin|/bin/false|"") continue ;;
    esac

    # Stop and disable user-scope systemd unit. systemctl --user needs to run as the user,
    # so we use 'runuser' or 'sudo -u' to invoke in their context.
    if command -v systemctl >/dev/null 2>&1; then
        # Set XDG_RUNTIME_DIR for the user's systemd instance
        export XDG_RUNTIME_DIR="/run/user/$uid"
        if [ -d "$XDG_RUNTIME_DIR" ]; then
            runuser -u "$username" -- systemctl --user stop gh-token-monitor.service 2>/dev/null && add_action "SYSTEMD_STOPPED:$username"
            runuser -u "$username" -- systemctl --user disable gh-token-monitor.service 2>/dev/null
            runuser -u "$username" -- systemctl --user daemon-reload 2>/dev/null
            log "Stopped systemd user unit for $username"
        else
            log "User $username has no active systemd session; will quarantine unit file only"
        fi
    fi

    # Quarantine the unit file and helper scripts
    for path in "$home/.config/systemd/user/gh-token-monitor.service" \
                "$home/.config/systemd/user/"*gh-token-monitor*.service \
                "$home/.local/bin/gh-token-monitor.sh" \
                "$home/.config/gh-token-monitor"; do
        [ -e "$path" ] && quarantine_file "$path"
    done
done < <(getent passwd)

# Kill any running payload processes
log "Step 1b: Kill suspicious processes"
pkill -f 'router_runtime|router_init|tanstack_runner|setup\.mjs|gh-token-monitor' 2>/dev/null && add_action "PROC_KILLED:pattern"
pkill -x bun 2>/dev/null && add_action "PROC_KILLED:bun"

# ---------------------------------------------------------------------------
# STEP 2: Quarantine payload files
# ---------------------------------------------------------------------------
log "Step 2: Quarantine payloads"
PAYLOAD_FILES="setup.mjs router_runtime.js router_init.js execution.js tanstack_runner.js"

while IFS=: read -r username _ uid _ _ home shell; do
    [ "$uid" -lt 500 ] && continue
    [ ! -d "$home" ] && continue
    case "$shell" in
        */nologin|/bin/false|"") continue ;;
    esac

    # 2a: home-level - skip tripwires
    for sub in .claude .vscode; do
        for fn in $PAYLOAD_FILES; do
            target="$home/$sub/$fn"
            [ ! -f "$target" ] && continue
            # Skip tripwires (placed by prevent script)
            if head -1 "$target" 2>/dev/null | grep -q 'Workspace ONE tripwire'; then
                continue
            fi
            quarantine_file "$target"
        done
    done

    # 2b: project scan
    SCANNED=0
    MAX_DIRS=500
    for root in "$home/code" "$home/dev" "$home/repos" "$home/src" \
                "$home/projects" "$home/work" "$home/git"; do
        [ ! -d "$root" ] && continue
        [ "$SCANNED" -ge "$MAX_DIRS" ] && break

        while IFS= read -r marker_dir; do
            [ "$SCANNED" -ge "$MAX_DIRS" ] && break
            SCANNED=$((SCANNED+1))
            for fn in $PAYLOAD_FILES; do
                target="$marker_dir/$fn"
                [ ! -f "$target" ] && continue
                if head -1 "$target" 2>/dev/null | grep -q 'Workspace ONE tripwire'; then
                    continue
                fi
                quarantine_file "$target"
            done
        done < <(find "$root" -maxdepth 4 \
                       \( -name node_modules -o -name .git \) -prune -o \
                       \( -type d \( -name .claude -o -name .vscode \) -print \) 2>/dev/null)
    done
done < <(getent passwd)

# ---------------------------------------------------------------------------
# STEP 3: Sanitize config files referencing IOCs
# ---------------------------------------------------------------------------
log "Step 3: Sanitize config files"
PAYLOAD_REGEX='router_runtime\.js|router_init\.js|tanstack_runner\.js|execution\.js|voicproducoes|EveryBoiWeBuildIsAWormyBoi|git-tanstack|A Mini Shai-Hulud has Appeared|Shai-Hulud: Here We Go Again|IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner'

sanitize_config() {
    local path="$1"
    [ ! -f "$path" ] && return
    local size
    size=$(stat -c %s "$path" 2>/dev/null)
    [ "${size:-0}" -gt 1048576 ] && return
    if grep -qE "$PAYLOAD_REGEX" "$path" 2>/dev/null; then
        quarantine_file "$path"
    fi
}

while IFS=: read -r username _ uid _ _ home shell; do
    [ "$uid" -lt 500 ] && continue
    [ ! -d "$home" ] && continue
    case "$shell" in
        */nologin|/bin/false|"") continue ;;
    esac

    sanitize_config "$home/.claude/settings.json"
    sanitize_config "$home/.claude/settings.local.json"
    sanitize_config "$home/.vscode/tasks.json"

    for root in "$home/code" "$home/dev" "$home/repos" "$home/src" "$home/projects" "$home/work" "$home/git"; do
        [ ! -d "$root" ] && continue
        while IFS= read -r marker_dir; do
            sanitize_config "$marker_dir/settings.json"
            sanitize_config "$marker_dir/settings.local.json"
            sanitize_config "$marker_dir/tasks.json"
        done < <(find "$root" -maxdepth 4 \
                       \( -name node_modules -o -name .git \) -prune -o \
                       \( -type d \( -name .claude -o -name .vscode \) -print \) 2>/dev/null)
    done
done < <(getent passwd)

# ---------------------------------------------------------------------------
# STEP 4: Lock files
# ---------------------------------------------------------------------------
log "Step 4: Remove lock files"
for lock_dir in /tmp /var/tmp; do
    for lock in tmp.987654321.lock tmp.ts018051808.lock; do
        quarantine_file "$lock_dir/$lock"
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ -z "$ACTIONS" ]; then
    SUMMARY="NOTHING_FOUND"
else
    ACTION_COUNT=$(echo "$ACTIONS" | awk -F';' '{print NF}')
    SUMMARY="ACTIONS:$ACTION_COUNT"
fi
log "=== shai_hulud_remediate complete: $SUMMARY ==="
echo "shai_hulud_remediate: $SUMMARY | quarantine: $QUAR_DIR | $ACTIONS"
