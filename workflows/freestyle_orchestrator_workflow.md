# Freestyle Orchestrator Workflow — Sensor-Triggered Remediation

This document describes the Workspace ONE Intelligence Freestyle Orchestrator workflow that wires the sensor's `STATUS:DETECTED` output to automatic execution of the remediate script.

## Overview

```
Sensor returns "STATUS:DETECTED..."
         │
         ▼
Intelligence trigger fires
         │
         ▼
Workflow condition: sensor value contains "STATUS:DETECTED"
         │
         ▼
Action 1: Run shai_hulud_remediate script on device
         │
         ▼
Action 2: Send Slack / email alert to security team
         │
         ▼
Action 3: Tag device with "shai-hulud-incident-<date>"
```

## Building it

### 1. Trigger setup

Workspace ONE Intelligence → Automations → Add Automation:

| Field | Value |
|---|---|
| Name | `shai_hulud_auto_remediate` |
| Service | Workspace ONE UEM |
| Category | Device Sensors |
| Trigger | Sensor data changed |

### 2. Filter

| Field | Operator | Value |
|---|---|---|
| `sensor.name` | Equals | `devtools_shai_hulud_check` |
| `sensor.value` | Contains | `STATUS:DETECTED` |

### 3. Action 1 — Run remediate

Action type: **Run Script**

| Field | Value |
|---|---|
| Script | `shai_hulud_remediate` (Windows OR macOS — create two automations, one per platform) |
| Execution Context | System |
| Pass parameters | None |

### 4. Action 2 — Alert

Action type: **Send Notification** (or **Slack** / **ServiceNow** / **Email** depending on what's wired into Intelligence)

Template:
```
🚨 Shai-Hulud detection on {device.friendly_name}

Device: {device.serial_number}
User: {device.user_name}
Platform: {device.platform}
Sensor output: {sensor.value}

Automated remediation has been triggered. Verify completion in Workspace ONE
and rotate the following credentials for this user:
- GitHub tokens (ghp_*, gho_*, ghs_*)
- npm tokens
- AWS / GCP / Azure access keys present on the device
- Any other org credentials this user holds

Remediate script details:
https://github.com/matt-coppinger/shai-hulud-defender
```

### 5. Action 3 — Tag

Action type: **Add Tag**

| Field | Value |
|---|---|
| Tag | `shai-hulud-incident-{trigger_date}` |

This creates a forensic record on the device and makes it easy to query "all devices with active incidents" in Intelligence dashboards.

## Important constraints

### Don't run remediate on every device with `STATUS:SUSPECT`

`SUSPECT` is a softer signal — it means a config file references known IOC strings, but no dropped payload was found. This could be a legitimate Claude Code config that mentions one of these names for unrelated reasons, or a partial infection that hasn't fully landed. Surface these to humans for review rather than auto-remediating.

### Rate-limit the automation

If a worm wave hits a large fraction of your developer population simultaneously, you can end up with hundreds of remediate scripts firing at once. Workspace ONE Intelligence has rate-limiting on automation triggers — set it conservatively (e.g., max 50 device actions per minute) so you don't overwhelm the UEM service or your incident channel.

### Don't auto-rotate credentials

The remediate script deliberately does not rotate credentials. If you're tempted to chain a credential-rotation action into this workflow:

- **Don't.** The dead-man's switch monitors for token revocation and triggers `rm -rf ~/`. The remediate script disables it first, but there's a race condition window.
- Add a manual approval gate before any credential-rotation action.
- Better: rotate credentials only after the remediate script has reported successful completion (i.e., quarantine log shows `DEADMAN:` action) — and even then, by human action.

## Manual override

If you want to test the workflow without waiting for a real detection, you can:

1. SSH/RDP to a test device
2. Manually create a file matching an IOC pattern (e.g., `touch ~/.claude/router_runtime.js` on macOS)
3. Force the sensor to re-run via the Workspace ONE Hub
4. Verify the workflow fires and the remediate script quarantines the file

Clean up after testing — the test file will end up in `/Library/Application Support/Omnissa/shai_hulud/quarantine/`.

## Tabletop exercise

Once a quarter, run a tabletop:

1. Plant IOC files on a test enrolled device
2. Verify sensor detection
3. Verify Intelligence alert fires
4. Verify remediate script runs
5. Verify alert reaches the right human responder
6. Verify the responder knows what to do next (credential rotation, forensic review)

If step 5 or 6 fails, that's the gap to close. The technical controls are necessary but not sufficient.

## Audit log

The remediate script writes to:
- Windows: `C:\ProgramData\Omnissa\shai_hulud\remediate.log`
- macOS: `/Library/Application Support/Omnissa/shai_hulud/remediate.log`

For incident response, collect these logs via a Workspace ONE Files action or have them shipped to your SIEM via the Hub agent's log forwarding.
