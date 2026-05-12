# Deployment Guide — Workspace ONE UEM

Step-by-step deployment for the three controls. Order matters: deploy prevent first, then sensor, then wire remediate via Freestyle.

## Prerequisites

- Workspace ONE UEM 2210 or later (sensors and scripts framework)
- Workspace ONE Intelligence (recommended for alerting)
- Freestyle Orchestrator (required for sensor → remediate automation)
- A Smart Group representing your developer population

## Phase 1 — Prevent (hardening)

### 1.1 Communicate the change

Before deploying, send a developer comms message. Template:

> Subject: **Heads up — npm/yarn/pnpm script execution will be disabled by default this Friday**
>
> To protect against the ongoing Mini Shai-Hulud supply-chain worm (TanStack, Mistral, UiPath, and others), we're disabling lifecycle script execution by default on managed dev machines.
>
> **What will break:** Packages that need `postinstall` to compile native code or download binaries — `husky`, `bcrypt`, `node-sass`, `puppeteer`, `playwright`, `cypress`, `esbuild`, `swc`, anything using `node-gyp`.
>
> **The escape hatch:** For any specific install that needs scripts:
> ```
> npm install --foreground-scripts <pkg>
> ```
>
> **Or to disable globally for a specific repo:**
> ```
> npm config set ignore-scripts false --location=project
> ```
>
> File a ticket in #devtools-support if you hit issues we haven't anticipated.

### 1.2 Upload the prevent scripts

**Windows:**
1. Resources → Scripts → Add → Windows
2. Name: `shai_hulud_prevent`
3. Description: "Hardens dev endpoints against Mini Shai-Hulud supply-chain worm"
4. Execution Context: **System**
5. Execution Architecture: Auto
6. Timeout: 600
7. Paste contents of `scripts/shai_hulud_prevent_windows.ps1`
8. Save & Assign to developer Smart Group
9. Trigger: On Enrolment + Recurring (Weekly)

**macOS:** Same flow, language = Bash, paste `scripts/shai_hulud_prevent_macos.sh`.

### 1.3 Verify

After scripts have run on test devices, verify:

**Windows:**
```powershell
# npmrc exists with ignore-scripts
type C:\ProgramData\npmrc

# Hosts file has the managed block
findstr "shai_hulud_prevent" C:\Windows\System32\drivers\etc\hosts

# Marker registry key exists
Get-ItemProperty HKLM:\SOFTWARE\Omnissa\ShaiHuludPrevent

# Tripwires exist and are read-only for at least one user
Get-ItemProperty C:\Users\<testuser>\.claude\setup.mjs | Select Mode, IsReadOnly
```

**macOS:**
```bash
# /etc/npmrc exists
cat /etc/npmrc

# Hosts file
grep shai_hulud_prevent /etc/hosts

# Marker
defaults read /Library/Preferences/com.omnissa.shai_hulud_prevent

# Tripwires immutable
ls -lO /Users/<testuser>/.claude/setup.mjs   # should show 'uchg'
```

## Phase 2 — Sensor

### 2.1 Upload the sensors

**Resources → Sensors → Add → Windows / macOS**

| Field | Value |
|---|---|
| Name | `devtools_shai_hulud_check` |
| Language | PowerShell / Bash |
| Execution Context | **User** (needs $HOME / %USERPROFILE%) |
| Response Data Type | String |
| Trigger | Schedule — Every 1 day |

Assign to developer Smart Group.

### 2.2 Verify

Wait for one sensor cycle, then check Device Details → Sensors. You should see `STATUS:CLEAN|scanned:N` where N is non-zero on developer machines with repos.

Note: The sensors are tripwire-aware. They skip files whose first line contains `Workspace ONE tripwire`, so the tripwires placed by the prevent script do not cause false `STATUS:DETECTED` reports.

## Phase 3 — Intelligence alerting

Workspace ONE Intelligence → Reports → Add Report:

- **Subject:** Devices
- **Filter:** Sensor `devtools_shai_hulud_check` → Contains → `STATUS:DETECTED`
- **Schedule:** Real-time alert via email / Slack / ServiceNow integration

Create a second report for `STATUS:SUSPECT` on a daily digest cadence.

## Phase 4 — Remediate (Freestyle Orchestrator)

See [`workflows/freestyle_orchestrator_workflow.md`](../workflows/freestyle_orchestrator_workflow.md) for the wiring.

## Rollback

If something goes badly wrong (which it might during initial rollout):

**Disable npm `ignore-scripts` machine-wide:**
- Windows: delete `C:\ProgramData\npmrc`
- macOS: `sudo rm /etc/npmrc`

**Restore hosts file:**
- Windows: edit `C:\Windows\System32\drivers\etc\hosts`, remove the `# BEGIN shai_hulud_prevent` block
- macOS: `sudo cp /etc/hosts.omnissa.bak /etc/hosts && sudo dscacheutil -flushcache`

**Remove tripwires** (must be done per-user, as the immutable flag prevents normal deletion):
- macOS: `sudo chflags nouchg ~/.claude/*.mjs ~/.vscode/*.mjs && rm ~/.claude/*.mjs ~/.vscode/*.mjs`
- Windows: `Remove-Item C:\Users\*\.claude\* -Force` (need to clear ACL first)

In all cases, the cleanest rollback is to unassign the prevent script from the Smart Group and run a cleanup script — but for emergency rollback, the steps above work per-device.
