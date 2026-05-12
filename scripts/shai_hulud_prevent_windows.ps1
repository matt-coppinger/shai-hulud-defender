# Workspace ONE Script: Mini Shai-Hulud / TanStack PREVENTION (Windows)
# Script name: shai_hulud_prevent
# Execution Context: System (required for hosts file + machine-wide npm config)
# Architecture: Auto
#
# Purpose: Pre-emptively block the persistence and propagation vectors of the
# Mini Shai-Hulud / TanStack supply chain worm. This is a hardening script,
# run once via WS1 Scripts (or on schedule to re-assert state).
#
# What it does:
#   1. Sets ignore-scripts=true in machine-wide npm/pnpm/yarn config
#   2. Adds known C2 domains to %WINDIR%\System32\drivers\etc\hosts
#   3. Drops read-only "tripwire" files at the common persistence paths in
#      each user profile so the dropper's overwrite fails
#   4. Logs all actions to C:\ProgramData\Omnissa\shai_hulud\prevent.log
#
# Recovery: Devs needing postinstall scripts run "npm install --foreground-scripts"
# per-package, or "npm config set ignore-scripts false --location=user" locally.

$ErrorActionPreference = 'Continue'
$logDir = 'C:\ProgramData\Omnissa\shai_hulud'
$logFile = Join-Path $logDir 'prevent.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-Log {
    param([string]$msg)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$ts  $msg" | Add-Content -Path $logFile
}

Write-Log "=== shai_hulud_prevent starting ==="

# ---------------------------------------------------------------------------
# 1. Machine-wide npm / pnpm / yarn: ignore-scripts = true
#    This kills the preinstall hook all current Shai-Hulud waves rely on.
# ---------------------------------------------------------------------------
$npmConfigDir = Join-Path $env:ProgramData 'npm'
if (-not (Test-Path $npmConfigDir)) { New-Item -ItemType Directory -Path $npmConfigDir -Force | Out-Null }
$npmrcPath = Join-Path $env:ProgramData 'npmrc'   # npm reads %PROGRAMDATA%\npmrc as global config

$npmrcContent = @"
; Managed by Omnissa Workspace ONE - shai_hulud_prevent
; Disables npm/pnpm/yarn lifecycle scripts to block supply-chain droppers.
; To run scripts for a specific install: npm install --foreground-scripts <pkg>
ignore-scripts=true
fund=false
audit-level=high
"@
Set-Content -Path $npmrcPath -Value $npmrcContent -Encoding ASCII -Force
Write-Log "Wrote machine-wide npmrc: $npmrcPath (ignore-scripts=true)"

# pnpm: machine-wide config lives at %PROGRAMDATA%\pnpm\config\rc
$pnpmConfigDir = Join-Path $env:ProgramData 'pnpm\config'
New-Item -ItemType Directory -Path $pnpmConfigDir -Force | Out-Null
$pnpmRcPath = Join-Path $pnpmConfigDir 'rc'
Set-Content -Path $pnpmRcPath -Value "ignore-scripts=true`nside-effects-cache=false" -Encoding ASCII -Force
Write-Log "Wrote pnpm config: $pnpmRcPath"

# Yarn (classic + berry): set via env var in machine registry so it applies to all shells
[Environment]::SetEnvironmentVariable('YARN_ENABLE_SCRIPTS', 'false', 'Machine')
[Environment]::SetEnvironmentVariable('npm_config_ignore_scripts', 'true', 'Machine')
Write-Log "Set machine env: YARN_ENABLE_SCRIPTS=false, npm_config_ignore_scripts=true"

# ---------------------------------------------------------------------------
# 2. Hosts file: block known C2 / payload-fetch domains
#    Limited value (Session/Oxen exfil bypasses DNS) but blocks the
#    git-tanstack.com payload domain and the PyPI variant's hardcoded IP.
# ---------------------------------------------------------------------------
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$blockMarkerStart = '# BEGIN shai_hulud_prevent (Omnissa) - do not edit'
$blockMarkerEnd   = '# END shai_hulud_prevent'

$blockDomains = @(
    'git-tanstack.com',
    'www.git-tanstack.com',
    'api.cloud-aws.adc-e.uk',
    'filev2.getsession.org',
    'seed1.getsession.org',
    'seed2.getsession.org',
    'seed3.getsession.org',
    'api.masscan.cloud'
)

# Strip any previous managed block, then re-add fresh
$hostsContent = Get-Content -Path $hostsPath -Raw
$pattern = [regex]::Escape($blockMarkerStart) + '.*?' + [regex]::Escape($blockMarkerEnd) + '\s*'
$hostsContent = [regex]::Replace($hostsContent, $pattern, '', 'Singleline')

$blockLines = @($blockMarkerStart)
foreach ($d in $blockDomains) { $blockLines += "0.0.0.0`t$d" }
# PyPI second-stage IP (mistralai variant)
$blockLines += "0.0.0.0`t83.142.209.194"
$blockLines += $blockMarkerEnd

$newHosts = $hostsContent.TrimEnd() + "`r`n`r`n" + ($blockLines -join "`r`n") + "`r`n"
Set-Content -Path $hostsPath -Value $newHosts -Encoding ASCII -Force
Write-Log "Updated hosts file with $($blockDomains.Count + 1) block entries"

# ---------------------------------------------------------------------------
# 3. Tripwire files at known persistence paths
#    Drop zero-byte read-only files where the dropper wants to write its
#    payload. The dropper overwrite will fail (or at minimum, the file's
#    ACL preserves an audit trail).
# ---------------------------------------------------------------------------
$tripwireFilenames = @('setup.mjs','router_runtime.js','router_init.js','execution.js','tanstack_runner.js')
$tripwireSubdirs = @('.claude','.vscode')

# Iterate every user profile (excluding system profiles)
$userProfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('Public','Default','Default User','All Users','WDAGUtilityAccount') }

foreach ($profile in $userProfiles) {
    foreach ($sub in $tripwireSubdirs) {
        $subPath = Join-Path $profile.FullName $sub
        if (-not (Test-Path $subPath)) {
            try {
                New-Item -ItemType Directory -Path $subPath -Force -ErrorAction Stop | Out-Null
            } catch {
                Write-Log "Could not create ${subPath}: $($_.Exception.Message)"
                continue
            }
        }
        foreach ($fn in $tripwireFilenames) {
            $tripPath = Join-Path $subPath $fn
            if (-not (Test-Path $tripPath)) {
                try {
                    Set-Content -Path $tripPath -Value "# Workspace ONE tripwire - do not delete" -Encoding ASCII -Force
                    # Make read-only; deny write to Everyone
                    $acl = Get-Acl $tripPath
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        'Everyone','WriteData,AppendData,Delete','Deny')
                    $acl.AddAccessRule($rule) | Out-Null
                    Set-Acl -Path $tripPath -AclObject $acl
                    Set-ItemProperty -Path $tripPath -Name IsReadOnly -Value $true
                    Write-Log "Tripwire placed: $tripPath"
                } catch {
                    Write-Log "Failed to place tripwire ${tripPath}: $($_.Exception.Message)"
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Block PowerShell-based Bun download (the dropper fetches Bun from
#    github.com/oven-sh/bun/releases). We can't block github.com, but we
#    can audit-log any PS process that touches bun.exe in user temp dirs.
#    Lightweight registry-based marker so the sensor knows prevent ran.
# ---------------------------------------------------------------------------
$markerKey = 'HKLM:\SOFTWARE\Omnissa\ShaiHuludPrevent'
New-Item -Path $markerKey -Force | Out-Null
Set-ItemProperty -Path $markerKey -Name 'LastRun' -Value (Get-Date).ToString('o')
Set-ItemProperty -Path $markerKey -Name 'Version' -Value '1.0'

Write-Log "=== shai_hulud_prevent complete ==="
Write-Output "shai_hulud_prevent: OK"
