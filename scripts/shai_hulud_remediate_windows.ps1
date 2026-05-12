# Workspace ONE Script: Mini Shai-Hulud / TanStack REMEDIATION (Windows)
# Script name: shai_hulud_remediate
# Execution Context: System (needs to touch every user profile and scheduled tasks)
# Architecture: Auto
#
# Trigger: Freestyle Orchestrator workflow when sensor returns STATUS:DETECTED
# (or run on-demand against a single device for forensic cleanup).
#
# CRITICAL ORDERING: Before doing anything else, disable the gh-token-monitor
# dead-man's switch. If the worm detects token revocation while the switch is
# armed, it can attempt destructive actions on the user's profile.
#
# What it does (in strict order):
#   1. Disable + remove gh-token-monitor scheduled task / service
#   2. Quarantine all dropped payload files to C:\ProgramData\Omnissa\shai_hulud\quarantine\<timestamp>\
#   3. Strip malicious entries from .claude/settings.json and .vscode/tasks.json
#   4. Remove lock files from %TEMP%
#   5. Log everything; return summary string
#
# What it does NOT do:
#   - Rotate credentials (must be done by humans - npm/GitHub/cloud)
#   - Touch the registry hosts file (handled by prevent script)
#   - Reinstall affected npm packages (do that from a clean cache)

$ErrorActionPreference = 'Continue'
$logDir = 'C:\ProgramData\Omnissa\shai_hulud'
$ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
$quarantineDir = Join-Path $logDir "quarantine\$ts"
$logFile = Join-Path $logDir 'remediate.log'
New-Item -ItemType Directory -Path $quarantineDir -Force | Out-Null

$actions = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$msg)
    $t = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$t  $msg" | Add-Content -Path $logFile
}

function Quarantine-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        # Flatten the source path into a safe filename so we keep provenance
        $safe = ($Path -replace '[:\\/]','_')
        $dest = Join-Path $quarantineDir $safe
        Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
        Write-Log "Quarantined: $Path -> $dest"
        $actions.Add("QUARANTINED:$Path")
        return $true
    } catch {
        Write-Log "Quarantine FAILED for ${Path}: $($_.Exception.Message)"
        $actions.Add("QUARANTINE_FAIL:$Path")
        return $false
    }
}

Write-Log "=== shai_hulud_remediate starting (quarantine=$quarantineDir) ==="

# ---------------------------------------------------------------------------
# STEP 1 - HIGHEST PRIORITY: disable the dead-man's switch.
# Must complete before anything that could look like token revocation.
# ---------------------------------------------------------------------------
Write-Log "Step 1: Disable gh-token-monitor"
$ghTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'gh-token-monitor|tanstack_runner' }
foreach ($t in $ghTasks) {
    try {
        Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
        Write-Log "Removed scheduled task: $($t.TaskPath)$($t.TaskName)"
        $actions.Add("TASK_REMOVED:$($t.TaskName)")
    } catch {
        Write-Log "Failed to remove task $($t.TaskName): $($_.Exception.Message)"
        $actions.Add("TASK_FAIL:$($t.TaskName)")
    }
}

$ghSvcs = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'gh-token-monitor' }
foreach ($s in $ghSvcs) {
    try {
        Stop-Service -Name $s.Name -Force -ErrorAction Stop
        sc.exe delete $s.Name | Out-Null
        Write-Log "Removed service: $($s.Name)"
        $actions.Add("SVC_REMOVED:$($s.Name)")
    } catch {
        Write-Log "Failed to remove service $($s.Name): $($_.Exception.Message)"
    }
}

# Also kill any running bun.exe or node.exe processes loading the payload
$susp = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and ($_.Path -match 'bun\.exe$' -or $_.CommandLine -match 'router_runtime|router_init|tanstack_runner|setup\.mjs')
}
foreach ($p in $susp) {
    try {
        Stop-Process -Id $p.Id -Force -ErrorAction Stop
        Write-Log "Killed PID $($p.Id) ($($p.Path))"
        $actions.Add("PROC_KILLED:$($p.Id)")
    } catch { Write-Log "Failed to kill PID $($p.Id)" }
}

# ---------------------------------------------------------------------------
# STEP 2: Quarantine payload files from all user profiles + common repo roots
# ---------------------------------------------------------------------------
Write-Log "Step 2: Quarantine payloads"
$payloadFiles = @('setup.mjs','router_runtime.js','router_init.js','execution.js','tanstack_runner.js')
$scanDirs = @('.claude','.vscode')

$userProfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('Public','Default','Default User','All Users','WDAGUtilityAccount') }

# 2a: home-directory locations
foreach ($profile in $userProfiles) {
    foreach ($sub in $scanDirs) {
        $dir = Join-Path $profile.FullName $sub
        if (Test-Path $dir) {
            foreach ($fn in $payloadFiles) {
                Quarantine-File -Path (Join-Path $dir $fn) | Out-Null
            }
        }
    }
}

# 2b: repo locations (depth-limited, bounded)
$projectRoots = @()
foreach ($profile in $userProfiles) {
    $projectRoots += @(
        (Join-Path $profile.FullName 'source\repos'),
        (Join-Path $profile.FullName 'source'),
        (Join-Path $profile.FullName 'repos'),
        (Join-Path $profile.FullName 'code'),
        (Join-Path $profile.FullName 'dev'),
        (Join-Path $profile.FullName 'projects'),
        (Join-Path $profile.FullName 'Documents\GitHub')
    )
}
$projectRoots += @('C:\src','C:\code','C:\dev','C:\repos')
$projectRoots = $projectRoots | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

$scanned = 0
$maxDirs = 500
foreach ($root in $projectRoots) {
    if ($scanned -ge $maxDirs) { break }
    $repoDirs = Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container) -or
                               (Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') -PathType Leaf) } |
                Select-Object -First ($maxDirs - $scanned)
    foreach ($r in $repoDirs) {
        $scanned++
        foreach ($sub in $scanDirs) {
            $dir = Join-Path $r.FullName $sub
            if (Test-Path $dir) {
                foreach ($fn in $payloadFiles) {
                    Quarantine-File -Path (Join-Path $dir $fn) | Out-Null
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 3: Sanitize settings.json / tasks.json - quarantine if they reference
# known payload strings. We don't try to surgically edit; cleaner to back up
# the whole file so the user can review/restore.
# ---------------------------------------------------------------------------
Write-Log "Step 3: Sanitize config files"
$payloadRegex = '(router_runtime\.js|router_init\.js|tanstack_runner\.js|execution\.js|voicproducoes|EveryBoiWeBuildIsAWormyBoi|git-tanstack|A Mini Shai-Hulud has Appeared|Shai-Hulud: Here We Go Again|IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner)'

function Sanitize-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -gt 1MB) { return }
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -match $payloadRegex) {
        Quarantine-File -Path $Path | Out-Null
    }
}

foreach ($profile in $userProfiles) {
    Sanitize-Config (Join-Path $profile.FullName '.claude\settings.json')
    Sanitize-Config (Join-Path $profile.FullName '.claude\settings.local.json')
    Sanitize-Config (Join-Path $profile.FullName '.vscode\tasks.json')
}

# ---------------------------------------------------------------------------
# STEP 4: Lock files
# ---------------------------------------------------------------------------
Write-Log "Step 4: Remove lock files"
$tempDirs = @($env:TEMP, "$env:WINDIR\Temp")
foreach ($profile in $userProfiles) { $tempDirs += (Join-Path $profile.FullName 'AppData\Local\Temp') }
foreach ($td in $tempDirs) {
    foreach ($lock in @('tmp.987654321.lock','tmp.ts018051808.lock')) {
        Quarantine-File -Path (Join-Path $td $lock) | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$summary = if ($actions.Count -eq 0) { "NOTHING_FOUND" } else { "ACTIONS:$($actions.Count)" }
Write-Log "=== shai_hulud_remediate complete: $summary (scanned $scanned repo dirs) ==="
Write-Output "shai_hulud_remediate: $summary | quarantine: $quarantineDir | $($actions -join ';')"
