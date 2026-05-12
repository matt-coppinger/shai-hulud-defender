#!/bin/bash
# Workspace ONE Sensor: Mini Shai-Hulud / TanStack persistence detection (macOS)
# Sensor name: devtools_shai_hulud_check
# Language: Bash
# Execution Context: User  (required to reach $HOME and ~/Library/LaunchAgents)
# Response Data Type: String
#
# Returns: "STATUS:CLEAN" or "STATUS:DETECTED|<findings>" or "STATUS:SUSPECT|<findings>"

set +e   # Don't bail on individual command failures; we want best-effort coverage.

USER_HOME="$HOME"
[ -z "$USER_HOME" ] && USER_HOME=$(eval echo "~$USER")

FINDINGS=""
STATUS="CLEAN"

PAYLOAD_FILES="setup.mjs router_runtime.js router_init.js execution.js tanstack_runner.js"
PAYLOAD_REGEX='router_runtime\.js|router_init\.js|tanstack_runner\.js|execution\.js|voicproducoes|EveryBoiWeBuildIsAWormyBoi|git-tanstack|A Mini Shai-Hulud has Appeared|Shai-Hulud: Here We Go Again|IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner'

add_finding() {
    local sev="$1"; local msg="$2"
    FINDINGS="${FINDINGS}${FINDINGS:+;}${msg}"
    # DETECTED beats SUSPECT beats CLEAN
    if [ "$sev" = "DETECTED" ]; then
        STATUS="DETECTED"
    elif [ "$sev" = "SUSPECT" ] && [ "$STATUS" != "DETECTED" ]; then
        STATUS="SUSPECT"
    fi
}

check_dropped_payloads() {
    local dir="$1"; local scope="$2"
    [ -d "$dir" ] || return
    for f in $PAYLOAD_FILES; do
        if [ -f "$dir/$f" ]; then
            # Skip tripwire files placed by the prevent script.
            # Tripwires contain "Workspace ONE tripwire" in their first line.
            if head -1 "$dir/$f" 2>/dev/null | grep -q 'Workspace ONE tripwire'; then
                continue
            fi
            add_finding "DETECTED" "PAYLOAD:${scope}/${f}"
        fi
    done
}

check_config_file() {
    local path="$1"; local scope="$2"
    [ -f "$path" ] || return
    # Skip files >1MB; legit settings files are tiny.
    local size
    size=$(stat -f %z "$path" 2>/dev/null || stat -c %s "$path" 2>/dev/null)
    [ "${size:-0}" -gt 1048576 ] && return
    if grep -qE "$PAYLOAD_REGEX" "$path" 2>/dev/null; then
        add_finding "SUSPECT" "CONFIG:${scope}"
    fi
}

# 1. Home-directory Claude / VS Code locations
check_dropped_payloads "$USER_HOME/.claude" "home/.claude"
check_dropped_payloads "$USER_HOME/.vscode" "home/.vscode"
check_config_file "$USER_HOME/.claude/settings.json" "home/.claude/settings.json"
check_config_file "$USER_HOME/.vscode/tasks.json"   "home/.vscode/tasks.json"

# 2. Lock files
for lock in tmp.987654321.lock tmp.ts018051808.lock; do
    if [ -f "/tmp/$lock" ] || [ -f "/var/tmp/$lock" ]; then
        add_finding "DETECTED" "LOCK:$lock"
    fi
done

# 3. gh-token-monitor LaunchAgent (macOS dead-man's switch)
for plist in "$USER_HOME/Library/LaunchAgents/com.user.gh-token-monitor.plist" \
             "$USER_HOME/Library/LaunchAgents/"*gh-token-monitor*.plist \
             "$USER_HOME/.config/systemd/user/gh-token-monitor.service" \
             "$USER_HOME/.local/bin/gh-token-monitor.sh"; do
    if [ -f "$plist" ]; then
        add_finding "DETECTED" "DEADMAN:$(basename "$plist")"
    fi
done

# 4. Project scan: bounded find. Limit depth and total directories visited.
SCANNED=0
MAX_DIRS=500
PROJECT_ROOTS="$USER_HOME/code $USER_HOME/dev $USER_HOME/repos $USER_HOME/src $USER_HOME/projects $USER_HOME/Documents/GitHub $USER_HOME/Developer $USER_HOME/Sites $USER_HOME/work"

for root in $PROJECT_ROOTS; do
    [ -d "$root" ] || continue
    [ "$SCANNED" -ge "$MAX_DIRS" ] && break

    # Find .claude or .vscode dirs up to 4 levels deep, excluding node_modules / .git internals
    while IFS= read -r marker_dir; do
        [ "$SCANNED" -ge "$MAX_DIRS" ] && break
        SCANNED=$((SCANNED+1))
        repo_dir=$(dirname "$marker_dir")
        repo_name=$(basename "$repo_dir")
        scope_prefix="repo:${repo_name}/$(basename "$marker_dir")"

        check_dropped_payloads "$marker_dir" "$scope_prefix"
        if [ "$(basename "$marker_dir")" = ".claude" ]; then
            check_config_file "$marker_dir/settings.json" "${scope_prefix}/settings.json"
            check_config_file "$marker_dir/settings.local.json" "${scope_prefix}/settings.local.json"
        else
            check_config_file "$marker_dir/tasks.json" "${scope_prefix}/tasks.json"
        fi
    done < <(find "$root" -maxdepth 4 \( -name node_modules -o -name .git -prune \) -o \
                          \( -type d \( -name .claude -o -name .vscode \) -print \) 2>/dev/null)
done

if [ -z "$FINDINGS" ]; then
    echo "STATUS:CLEAN|scanned:$SCANNED"
else
    echo "STATUS:${STATUS}|scanned:${SCANNED}|${FINDINGS}"
fi
