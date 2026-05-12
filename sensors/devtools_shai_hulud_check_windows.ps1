# Workspace ONE Sensor: Mini Shai-Hulud / TanStack persistence detection (Windows)
# Sensor name: devtools_shai_hulud_check
# Language: PowerShell
# Execution Context: User  (required to reach %USERPROFILE%)
# Execution Architecture: Auto
# Response Data Type: String
#
# Returns: "STATUS:CLEAN" or "STATUS:DETECTED|<findings>" or "STATUS:SUSPECT|<findings>"
# DETECTED = high-confidence IOC (dropped payload file on disk, known service)
# SUSPECT  = config file references known-bad strings (needs human review)
#
# IOCs covered (sources: Mend, Endor, Wiz, Socket, Snyk, Semgrep, May 2026):
#   ~/.claude/setup.mjs, ~/.claude/router_runtime.js, ~/.claude/router_init.js,
#   ~/.claude/execution.js, ~/.claude/tanstack_runner.js
#   ~/.vscode/setup.mjs
#   Per-repo: <repo>/.claude/{settings.json,setup.mjs,router_runtime.js,router_init.js}
#   Per-repo: <repo>/.vscode/{tasks.json,setup.mjs}
#   Lock files: %TEMP%\tmp.987654321.lock, tmp.ts018051808.lock
#   Scheduled task / service named gh-token-monitor (Win equivalent of LaunchAgent)

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[string]]::new()
$status = 'CLEAN'

# Tight regex: requires malware-specific tokens, not just generic Claude/VSCode keywords.
# 'SessionStart' alone is legitimate; 'SessionStart' + 'setup.mjs' is not.
$payloadFiles = @('setup.mjs','router_runtime.js','router_init.js','execution.js','tanstack_runner.js')
$payloadRegex = '(router_runtime\.js|router_init\.js|tanstack_runner\.js|execution\.js|voicproducoes|EveryBoiWeBuildIsAWormyBoi|git-tanstack|A Mini Shai-Hulud has Appeared|Shai-Hulud: Here We Go Again|IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner)'

function Test-DroppedPayload {
    param([string]$Dir, [string]$Scope)
    foreach ($f in $payloadFiles) {
        $p = Join-Path $Dir $f
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $findings.Add("PAYLOAD:$Scope/$f")
            $script:status = 'DETECTED'
        }
    }
}

function Test-ConfigFile {
    param([string]$Path, [string]$Scope)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -gt 1MB) { return }  # legit config files are small; skip huge files
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -match $payloadRegex) {
        $findings.Add("CONFIG:$Scope")
        if ($script:status -ne 'DETECTED') { $script:status = 'SUSPECT' }
    }
}

$userHome = [Environment]::GetFolderPath('UserProfile')

# 1. Global Claude / VS Code locations (the original sensor's scope)
Test-DroppedPayload -Dir (Join-Path $userHome '.claude') -Scope 'home/.claude'
Test-DroppedPayload -Dir (Join-Path $userHome '.vscode') -Scope 'home/.vscode'
Test-ConfigFile -Path (Join-Path $userHome '.claude\settings.json') -Scope 'home/.claude/settings.json'
Test-ConfigFile -Path (Join-Path $userHome '.vscode\tasks.json')   -Scope 'home/.vscode/tasks.json'

# 2. Lock files left by the dropper
foreach ($lock in @('tmp.987654321.lock','tmp.ts018051808.lock')) {
    $lp = Join-Path $env:TEMP $lock
    if (Test-Path -LiteralPath $lp) {
        $findings.Add("LOCK:$lock")
        $status = 'DETECTED'
    }
}

# 3. gh-token-monitor as scheduled task or service
$ghMon = Get-ScheduledTask | Where-Object { $_.TaskName -match 'gh-token-monitor' }
if ($ghMon) { $findings.Add("SCHEDTASK:gh-token-monitor"); $status = 'DETECTED' }
$ghSvc = Get-Service | Where-Object { $_.Name -match 'gh-token-monitor' }
if ($ghSvc) { $findings.Add("SERVICE:gh-token-monitor"); $status = 'DETECTED' }

# 4. Project scan: walk common dev roots, depth-limited, with hard cap on dirs visited.
#    We look for repos (anything containing a .git folder OR a package.json) within the
#    first 4 levels and check their .claude/ and .vscode/ subfolders only.
$projectRoots = @(
    (Join-Path $userHome 'source'),
    (Join-Path $userHome 'source\repos'),
    (Join-Path $userHome 'repos'),
    (Join-Path $userHome 'code'),
    (Join-Path $userHome 'dev'),
    (Join-Path $userHome 'projects'),
    (Join-Path $userHome 'Documents\GitHub'),
    (Join-Path $userHome 'OneDrive\Documents\GitHub'),
    'C:\src','C:\code','C:\dev','C:\repos'
) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

$scanned = 0
$maxDirs = 500   # hard cap to keep sensor under WS1 timeout on dev machines with many repos

foreach ($root in $projectRoots) {
    if ($scanned -ge $maxDirs) { break }
    # Find candidate repo dirs up to depth 3 from each root
    $candidates = Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                  Where-Object {
                      (Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container) -or
                      (Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') -PathType Leaf)
                  } | Select-Object -First ($maxDirs - $scanned)
    foreach ($c in $candidates) {
        $scanned++
        $claudeDir = Join-Path $c.FullName '.claude'
        $vscodeDir = Join-Path $c.FullName '.vscode'
        if (Test-Path -LiteralPath $claudeDir -PathType Container) {
            Test-DroppedPayload -Dir $claudeDir -Scope "repo:$($c.Name)/.claude"
            Test-ConfigFile -Path (Join-Path $claudeDir 'settings.json') -Scope "repo:$($c.Name)/.claude/settings.json"
            Test-ConfigFile -Path (Join-Path $claudeDir 'settings.local.json') -Scope "repo:$($c.Name)/.claude/settings.local.json"
        }
        if (Test-Path -LiteralPath $vscodeDir -PathType Container) {
            Test-DroppedPayload -Dir $vscodeDir -Scope "repo:$($c.Name)/.vscode"
            Test-ConfigFile -Path (Join-Path $vscodeDir 'tasks.json') -Scope "repo:$($c.Name)/.vscode/tasks.json"
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Output "STATUS:CLEAN|scanned:$scanned"
} else {
    Write-Output ("STATUS:{0}|scanned:{1}|{2}" -f $status, $scanned, ($findings -join ';'))
}
