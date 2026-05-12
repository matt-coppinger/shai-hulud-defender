#!/bin/bash
# Workspace ONE Script: Mini Shai-Hulud / TanStack REMEDIATION (macOS)
# Script name: shai_hulud_remediate
# Execution Context: System (needs to touch every user's home and LaunchAgents)
#
# Trigger: Freestyle Orchestrator workflow when sensor returns STATUS:DETECTED
#
# CRITICAL ORDERING: Disable the gh-token-monitor LaunchAgent FIRST. The worm
# polls every 60 seconds and triggers `rm -rf ~/` on HTTP 40x. If we touch
# anything else first, we risk armed token revocation.
#
# Order:
#   1. Unload + remove gh-token-monitor LaunchAgents and systemd-like helpers
#   2. Kill any bun / suspicious node processes
#   3. Quarantine payload files to /Library/Application Support/Omnissa/shai_hulud/quarantine/<ts>/
#   4. Quarantine settings.json / tasks.json that reference IOCs
#   5. Remove lock files
#
# What it does NOT do:
#   - Rotate credentials (humans must do this; npm/GitHub/cloud)
#   - Modify /etc/hosts (handled by prevent script)
#   - Trigger Russian-locale fake (the malware has its own locale check)

set +e

LOG_DIR="/Library/Application Support/Omnissa/shai_hulud"
TS=$(date '+%Y%m%d_%H%M%S')
QUAR_DIR="$LOG_DIR/quarantine/$TS"
LOG_FILE="$LOG_DIR/remediate.log"
mkdir -p "$QUAR_DIR"

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
    chflags nouchg "$path" 2>/dev/null
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

# Iterate all real users to unload per-user LaunchAgents
while IFS=: read -r username _ uid _ _ home shell; do
    [ "$uid" -lt 500 ] && continue
    [ ! -d "$home" ] && continue
    case "$home" in /Users/*) ;; *) continue ;; esac

    # Look for any LaunchAgent matching gh-token-monitor pattern
    for plist in "$home/Library/LaunchAgents/"*gh-token-monitor*.plist \
                 "$home/Library/LaunchAgents/com.user.gh-token-monitor.plist" \
                 "$home/Library/LaunchAgents/"*tanstack*.plist; do
        [ ! -f "$plist" ] && continue
        log "Found LaunchAgent: $plist"

        # Unload in the user's launchd context (need their UID)
        launchctl bootout "gui/$uid" "$plist" 2>/dev/null
        launchctl unload "$plist" 2>/dev/null

        quarantine_file "$plist"
    done

    # Helper scripts the LaunchAgent invokes
    for helper in "$home/.local/bin/gh-token-monitor.sh" \
                  "$home/.config/gh-token-monitor/"* \
                  "$home/.config/systemd/user/gh-token-monitor.service"; do
        [ -e "$helper" ] && quarantine_file "$helper"
    done
done < <(dscl . -list /Users UniqueID | awk '$2 >= 500 {print $1":x:"$2":20:User:/Users/"$1":/bin/zsh"}')

# Kill bun + suspicious node processes (in case daemon is mid-poll)
log "Step 1b: Kill suspicious processes"
# pkill returns 0 if it killed anything, 1 if no match. Don't let it fail the script.
pkill -f 'router_runtime|router_init|tanstack_runner|setup\.mjs|gh-token-monitor' 2>/dev/null && add_action "PROC_KILLED:pattern"
pkill -x bun 2>/dev/null && add_action "PROC_KILLED:bun"

# ---------------------------------------------------------------------------
# STEP 2: Quarantine payload files from home dirs + project roots
# ---------------------------------------------------------------------------
log "Step 2: Quarantine payloads"
PAYLOAD_FILES="setup.mjs router_runtime.js router_init.js execution.js tanstack_runner.js"

while IFS=: read -r username _ uid _ _ home shell; do
    [ "$uid" -lt 500 ] && continue
    [ ! -d "$home" ] && continue
    case "$home" in /Users/*) ;; *) continue ;; esac

    # 2a: home-level .claude / .vscode
    for sub in .claude .vscode; do
        for fn in $PAYLOAD_FILES; do
            quarantine_file "$home/$sub/$fn"
        done
    done

    # 2b: bounded project scan
    SCANNED=0
    MAX_DIRS=500
    for root in "$home/code" "$home/dev" "$home/repos" "$home/src" \
                "$home/projects" "$home/Documents/GitHub" "$home/Developer" \
                "$home/Sites" "$home/work"; do
        [ ! -d "$root" ] && continue
        [ "$SCANNED" -ge "$MAX_DIRS" ] && break

        while IFS= read -r marker_dir; do
            [ "$SCANNED" -ge "$MAX_DIRS" ] && break
            SCANNED=$((SCANNED+1))
            for fn in $PAYLOAD_FILES; do
                quarantine_file "$marker_dir/$fn"
            done
        done < <(find "$root" -maxdepth 4 \
                       \( -name node_modules -o -name .git \) -prune -o \
                       \( -type d \( -name .claude -o -name .vscode \) -print \) 2>/dev/null)
    done
done < <(dscl . -list /Users UniqueID | awk '$2 >= 500 {print $1":x:"$2":20:User:/Users/"$1":/bin/zsh"}')

# ---------------------------------------------------------------------------
# STEP 3: Sanitize config files that reference IOCs
# ---------------------------------------------------------------------------
log "Step 3: Sanitize config files"
PAYLOAD_REGEX='router_runtime\.js|router_init\.js|tanstack_runner\.js|execution\.js|voicproducoes|EveryBoiWeBuildIsAWormyBoi|git-tanstack|A Mini Shai-Hulud has Appeared|Shai-Hulud: Here We Go Again|IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner'

sanitize_config() {
    local path="$1"
    [ ! -f "$path" ] && return
    local size
    size=$(stat -f %z "$path" 2>/dev/null)
    [ "${size:-0}" -gt 1048576 ] && return
    if grep -qE "$PAYLOAD_REGEX" "$path" 2>/dev/null; then
        quarantine_file "$path"
    fi
}

while IFS=: read -r username _ uid _ _ home shell; do
    [ "$uid" -lt 500 ] && continue
    [ ! -d "$home" ] && continue
    case "$home" in /Users/*) ;; *) continue ;; esac

    sanitize_config "$home/.claude/settings.json"
    sanitize_config "$home/.claude/settings.local.json"
    sanitize_config "$home/.vscode/tasks.json"

    # Per-repo configs too
    for root in "$home/code" "$home/dev" "$home/repos" "$home/src" \
                "$home/projects" "$home/Documents/GitHub" "$home/Developer"; do
        [ ! -d "$root" ] && continue
        while IFS= read -r marker_dir; do
            sanitize_config "$marker_dir/settings.json"
            sanitize_config "$marker_dir/settings.local.json"
            sanitize_config "$marker_dir/tasks.json"
        done < <(find "$root" -maxdepth 4 \
                       \( -name node_modules -o -name .git \) -prune -o \
                       \( -type d \( -name .claude -o -name .vscode \) -print \) 2>/dev/null)
    done
done < <(dscl . -list /Users UniqueID | awk '$2 >= 500 {print $1":x:"$2":20:User:/Users/"$1":/bin/zsh"}')

# ---------------------------------------------------------------------------
# STEP 4: Lock files
# ---------------------------------------------------------------------------
log "Step 4: Remove lock files"
for lock_dir in /tmp /var/tmp /private/tmp; do
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
