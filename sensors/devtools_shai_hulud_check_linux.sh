#!/bin/bash
# Workspace ONE Sensor: Mini Shai-Hulud / TanStack persistence detection (Linux)
# Sensor name: devtools_shai_hulud_check
# Language: Bash
# Execution Context: User  (required to reach $HOME)
# Response Data Type: String
# Trigger: Periodic (Linux WS1 sensors are schedule-only, no event triggers)
#
# Returns: "STATUS:CLEAN" or "STATUS:DETECTED|<findings>" or "STATUS:SUSPECT|<findings>"
#
# Linux-specific IOCs:
#   ~/.config/systemd/user/gh-token-monitor.service  (systemd user unit dead-man)
#   ~/.local/bin/gh-token-monitor.sh                 (helper script)
#   /tmp/tmp.987654321.lock, /tmp/tmp.ts018051808.lock
#   All the same .claude/, .vscode/ persistence as macOS

set +e

USER_HOME="$HOME"
[ -z "$USER_HOME" ] && USER_HOME=$(getent passwd "$USER" | cut -d: -f6)

FINDINGS=""
STATUS="CLEAN"

PAYLOAD_FILES="setup.mjs router_runtime.js router_init.js execution.js tanstack_runner.js"
PAYLOAD_REGEX='router_runtime\.js|router_init\.js|tanstack_runner\.js|execution\.js|voicproducoes|EveryBoiWeBuildIsAWormyBoi|git-tanstack|A Mini Shai-Hulud has Appeared|Shai-Hulud: Here We Go Again|IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner'

add_finding() {
    local sev="$1"; local msg="$2"
    FINDINGS="${FINDINGS}${FINDINGS:+;}${msg}"
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
            # Skip tripwires placed by prevent script
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
    local size
    size=$(stat -c %s "$path" 2>/dev/null)
    [ "${size:-0}" -gt 1048576 ] && return
    if grep -qE "$PAYLOAD_REGEX" "$path" 2>/dev/null; then
        add_finding "SUSPECT" "CONFIG:${scope}"
    fi
}

# 1. Home-directory locations
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

# 3. systemd user units (Linux dead-man's switch)
for unit in "$USER_HOME/.config/systemd/user/gh-token-monitor.service" \
            "$USER_HOME/.config/systemd/user/"*gh-token-monitor*.service \
            "$USER_HOME/.local/bin/gh-token-monitor.sh" \
            "$USER_HOME/.config/gh-token-monitor"; do
    if [ -e "$unit" ]; then
        add_finding "DETECTED" "DEADMAN:$(basename "$unit")"
    fi
done

# 3b. Check if the user-scope systemd unit is actually active
if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-active gh-token-monitor.service >/dev/null 2>&1; then
        add_finding "DETECTED" "DEADMAN:active_systemd_unit"
    fi
fi

# 4. Project scan
SCANNED=0
MAX_DIRS=500
PROJECT_ROOTS="$USER_HOME/code $USER_HOME/dev $USER_HOME/repos $USER_HOME/src $USER_HOME/projects $USER_HOME/work $USER_HOME/git"

for root in $PROJECT_ROOTS; do
    [ -d "$root" ] || continue
    [ "$SCANNED" -ge "$MAX_DIRS" ] && break

    while IFS= read -r marker_dir; do
        [ "$SCANNED" -ge "$MAX_DIRS" ] && break
        SCANNED=$((SCANNED+1))
        repo_name=$(basename "$(dirname "$marker_dir")")
        scope_prefix="repo:${repo_name}/$(basename "$marker_dir")"

        check_dropped_payloads "$marker_dir" "$scope_prefix"
        if [ "$(basename "$marker_dir")" = ".claude" ]; then
            check_config_file "$marker_dir/settings.json" "${scope_prefix}/settings.json"
            check_config_file "$marker_dir/settings.local.json" "${scope_prefix}/settings.local.json"
        else
            check_config_file "$marker_dir/tasks.json" "${scope_prefix}/tasks.json"
        fi
    done < <(find "$root" -maxdepth 4 \( -name node_modules -o -name .git \) -prune -o \
                          \( -type d \( -name .claude -o -name .vscode \) -print \) 2>/dev/null)
done

if [ -z "$FINDINGS" ]; then
    echo "STATUS:CLEAN|scanned:$SCANNED"
else
    echo "STATUS:${STATUS}|scanned:${SCANNED}|${FINDINGS}"
fi
