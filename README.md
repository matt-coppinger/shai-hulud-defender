# shai-hulud-defender

Workspace ONE UEM sensors and scripts to detect, prevent, and remediate the **Mini Shai-Hulud** (TanStack / TeamPCP) supply-chain worm campaign on Windows and macOS endpoints.

> **Status:** Defensive controls only. This repo does not contain offensive tooling or malware samples.
> **Maintained for:** Workspace ONE UEM (Omnissa) customers managing developer endpoints.
> **Last updated:** 2026-05-13 — IOCs current through the May 11–13 TanStack wave (CVE-2026-45321, CVSS 9.6).

---

## What this is

Three coordinated controls per platform:

| Control | What it does | When it runs |
|---|---|---|
| **Sensor** | Reports `STATUS:CLEAN` / `SUSPECT` / `DETECTED` | Daily, scheduled |
| **Prevent script** | Hardens the endpoint against the known persistence and propagation paths | Once on enrolment, then weekly to re-assert state |
| **Remediate script** | Disables the dead-man's switch, quarantines payloads, sanitises config files | Triggered by Freestyle Orchestrator when the sensor returns `STATUS:DETECTED` |

The three pieces are designed to work together. The prevent script puts tripwires in place that the sensor knows to ignore (via a content marker), and the sensor's `DETECTED` output triggers the remediate script via Freestyle Orchestrator.

---

## What this is not

This is **endpoint defence**. It is not a substitute for the controls that actually stop supply-chain worms entering your organisation:

- A registry proxy with package allowlisting (Sonatype Nexus, JFrog Artifactory)
- A registry-aware scanner in CI (Socket, Snyk, Sonatype IQ, JFrog Xray)
- Cooldown windows on new package versions before they're allowed in builds
- OIDC trust hygiene on your CI/CD publishing pipelines
- SHA-pinned GitHub Actions (not `@v3` tags)

If you don't have those in place, this repo is a forensic backstop, not prevention. Have the conversation with whoever owns AppSec before relying on these scripts alone.

---

## The threat in 90 seconds

Mini Shai-Hulud is an evolving family of self-propagating npm supply-chain worms attributed to the group TeamPCP. Major waves:

- **April 29, 2026** — SAP CAP packages (`mbt`, `@cap-js/sqlite`, `@cap-js/postgres`, `@cap-js/db-service`)
- **April 30, 2026** — PyPI: `lightning` 2.6.2/2.6.3
- **May 11–12, 2026** — TanStack (`@tanstack/react-router` + 41 others), UiPath, Mistral AI, Guardrails AI, OpenSearch. Over 170 packages, 400+ million combined weekly downloads. CVE-2026-45321.

What it does on a developer machine:

1. **Entry**: An npm `preinstall` hook (or, in the TanStack variant, a malicious `optionalDependencies` git-ref) runs `setup.mjs`
2. **Dropper**: `setup.mjs` downloads Bun from `github.com/oven-sh/bun/releases`, then executes `router_init.js` / `router_runtime.js` — an obfuscated ~2.3 MB credential stealer
3. **Credential sweep**: GitHub tokens (`ghp_`, `gho_`, `ghs_`), npm tokens, AWS / GCP / Azure credentials, Vault tokens, Kubernetes service accounts
4. **Persistence**: SessionStart hooks in `.claude/settings.json` and `folderOpen` triggers in `.vscode/tasks.json`. Payload binaries dropped into `.claude/` and `.vscode/`
5. **Exfil**: Four redundant channels — HTTPS to `git-tanstack.com`, Session/Oxen E2E network (`*.getsession.org`), GitHub commit-search dead-drop, and attacker-controlled public GitHub repos
6. **Dead-man's switch**: A `gh-token-monitor` LaunchAgent (macOS) or systemd user service (Linux) — or a `pgmonitor.py` / `pgsql-monitor.service` variant in newer drops — polls `api.github.com/user` every 60 seconds. On HTTP 40x (token revoked) it attempts `rm -rf ~/`

> ⚠️ **Critical:** Before rotating any potentially-compromised tokens, **disable the dead-man's switch first**. The remediate scripts in this repo do this automatically as Step 1.

Primary IOC sources: [Mend.io](https://www.mend.io/blog/mini-shai-hulud-is-back-172-npm-and-pypi-packages-compromised-in-latest-wave/), [Socket](https://socket.dev/blog/tanstack-npm-packages-compromised-mini-shai-hulud-supply-chain-attack), [Wiz](https://www.wiz.io/blog/mini-shai-hulud-strikes-again-tanstack-more-npm-packages-compromised), [Endor Labs](https://www.endorlabs.com/learn/mini-shai-hulud-npm-worm-hits-sap-developer-packages), [Snyk](https://snyk.io/blog/tanstack-npm-packages-compromised/), [StepSecurity](https://www.stepsecurity.io/blog/mini-shai-hulud-is-back-a-self-spreading-supply-chain-attack-hits-the-npm-ecosystem).

---

## Repo layout

```
shai-hulud-defender/
├── sensors/
│   ├── devtools_shai_hulud_check_windows.ps1
│   ├── devtools_shai_hulud_check_macos.sh
│   └── devtools_shai_hulud_check_linux.sh
├── scripts/
│   ├── shai_hulud_prevent_windows.ps1      # Hardening — run on enrolment + weekly
│   ├── shai_hulud_prevent_macos.sh
│   ├── shai_hulud_prevent_linux.sh
│   ├── shai_hulud_remediate_windows.ps1    # Cleanup — trigger via Freestyle on DETECTED
│   ├── shai_hulud_remediate_macos.sh
│   └── shai_hulud_remediate_linux.sh
├── workflows/
│   └── freestyle_orchestrator_workflow.md  # Step-by-step Freestyle wiring
├── docs/
│   ├── iocs.md                             # Current IOC list, updated per wave
│   ├── deployment.md                       # Workspace ONE deployment steps
│   ├── breakage.md                         # Known breakage from ignore-scripts=true
│   ├── linux-notes.md                      # Linux-specific deployment notes
│   └── threat-model.md                     # What this catches and what it doesn't
├── LICENSE
└── README.md
```

---

## Quick start (Workspace ONE UEM)

### 1. The sensor

**Resources → Sensors → Add → Windows / macOS / Linux**.

| Field | Windows | macOS | Linux |
|---|---|---|---|
| Name | `devtools_shai_hulud_check` | `devtools_shai_hulud_check` | `devtools_shai_hulud_check` |
| Language | PowerShell | Bash | Bash |
| Execution Context | User | User | User |
| Architecture | Auto | n/a | n/a |
| Response Data Type | String | String | String |
| Script | `sensors/devtools_shai_hulud_check_windows.ps1` | `sensors/devtools_shai_hulud_check_macos.sh` | `sensors/devtools_shai_hulud_check_linux.sh` |

Assign to developer Smart Group(s). Schedule daily. Note: Linux sensors in Workspace ONE only support periodic triggers, not event-based ones.

**Sample outputs:**
```
STATUS:CLEAN|scanned:23
STATUS:SUSPECT|scanned:23|CONFIG:repo:my-app/.claude/settings.json
STATUS:DETECTED|scanned:23|PAYLOAD:home/.claude/router_runtime.js;DEADMAN:com.user.gh-token-monitor.plist
```

Alert in Intelligence on `Contains "STATUS:DETECTED"`. Dashboard on `STATUS:SUSPECT`.

### 2. The prevent script (one-time hardening)

**Resources → Scripts → Add → Windows / macOS**.

| Field | Value |
|---|---|
| Name | `shai_hulud_prevent` |
| Execution Context | **System** (required for `/etc/hosts`, `%PROGRAMDATA%`, all user profiles) |
| Timeout | 600s |

Assign to all developer-Smart-Group devices. Schedule weekly to re-assert state (hosts file and tripwires can drift).

> ⚠️ **Will break installs that need `postinstall` hooks**. See [`docs/breakage.md`](docs/breakage.md) for the affected package list and the per-install escape hatch. Communicate to developers before deploying.

### 3. The remediate script (triggered)

Add to **Resources → Scripts** in the same way as prevent. Wire it via Freestyle Orchestrator — see [`workflows/freestyle_orchestrator_workflow.md`](workflows/freestyle_orchestrator_workflow.md) for step-by-step.

The trigger is: *Sensor `devtools_shai_hulud_check` returns a value containing `STATUS:DETECTED` → run `shai_hulud_remediate` on the device.*

---

## What the prevent scripts actually do

1. **Set `ignore-scripts=true` at machine scope** for npm, pnpm, yarn classic, and yarn berry. Every current Shai-Hulud wave relies on an npm lifecycle script firing. No lifecycle script = no dropper = no payload. **This is the single highest-leverage change.** Per-install escape: `npm install --foreground-scripts <pkg>`.

2. **Block known C2 / payload-fetch endpoints in the hosts file:** `git-tanstack.com`, `*.getsession.org`, `api.cloud-aws.adc-e.uk`, `api.masscan.cloud`, and `83.142.209.194` (the PyPI variant's hardcoded IP). Partial coverage only — the Session/Oxen channel is E2E-encrypted with no central C2.

3. **Drop read-only tripwire files** at `~/.claude/{setup.mjs,setup.sh,router_runtime.js,router_init.js,execution.js,tanstack_runner.js,opensearch_init.js}` and `~/.vscode/` for every user profile. Even if `ignore-scripts` is bypassed somehow, the dropper's `writeFileSync` will fail because the file is immutable (`chflags uchg` on macOS, `chattr +i` on Linux, deny-write ACL on Windows). Belt-and-braces.

4. **Write a marker** at `HKLM:\SOFTWARE\Omnissa\ShaiHuludPrevent` (Windows) or `/Library/Preferences/com.omnissa.shai_hulud_prevent` (macOS) so the sensor can confirm prevent has run.

## What the remediate scripts actually do

**Step 1 (highest priority): disable the dead-man's switch.** Unloads and quarantines the `gh-token-monitor` and `pgmonitor` / `pgsql-monitor` LaunchAgents, scheduled tasks, services, and systemd user units before doing anything else. The malware polls every 60 seconds — if it detects token revocation or its own files being touched while the switch is armed, it attempts `rm -rf ~/`.

**Step 2: kill running payload processes** (`bun`, anything with `router_runtime` / `router_init` / `tanstack_runner` / `opensearch_init` / `pgmonitor` / `pgsql-monitor` / `roulette.py` / `setup.mjs` / `setup.sh` / `gh-token-monitor` in cmdline).

**Step 3: quarantine** all known payload files from `~/.claude/`, `~/.vscode/`, and per-repo `.claude/`/`.vscode/` directories (depth-limited, capped at 500 dirs). Files are moved to a timestamped folder under `/Library/Application Support/Omnissa/shai_hulud/quarantine/` (macOS) or `C:\ProgramData\Omnissa\shai_hulud\quarantine\` (Windows). Filenames preserve original paths.

**Step 4: sanitise** any `settings.json` / `tasks.json` that references known IOC strings — these go into quarantine intact rather than being surgically edited, so the IR team can review them.

**Step 5: remove lock files** (`tmp.987654321.lock`, `tmp.ts018051808.lock`) from temp directories.

**What remediate does NOT do:**
- Rotate credentials. That's a human-judgement call (which tokens, in what order, with what blast radius)
- Modify the hosts file (handled by prevent)
- Reinstall affected npm packages — clear the cache and reinstall from a clean lockfile manually

---

## Threat coverage matrix

| Attack stage | Covered? | By what |
|---|---|---|
| Malicious package enters registry | ❌ | Out of scope — needs registry proxy |
| `preinstall` lifecycle fires on `npm install` | ✅ | `ignore-scripts=true` (prevent) |
| Dropper writes payload to disk | 🟡 | Tripwire files (prevent), but bypassable |
| Dropper downloads Bun from github.com | ❌ | Can't block github.com |
| Payload exfiltrates via `git-tanstack.com` | ✅ | Hosts file (prevent) |
| Payload exfiltrates via Session/Oxen | 🟡 | Hosts file blocks seed nodes, but the network can route around |
| Payload exfiltrates via GitHub commit-search dead-drop | ❌ | Can't block github.com |
| Persistence via `.claude/settings.json` | ✅ | Detected (sensor) + quarantined (remediate) |
| Persistence via `.vscode/tasks.json` | ✅ | Detected + quarantined |
| `gh-token-monitor` / `pgmonitor` / `pgsql-monitor` LaunchAgent / scheduled task / systemd unit | ✅ | Detected + disabled first in remediate |
| Worm propagates via stolen npm token | 🟡 | Only if dev's machine is the source; can't stop CI-side propagation |
| Worm propagates via OIDC token theft from CI | ❌ | Out of scope — needs CI hardening |

---

## Caveats — please read before deploying

1. **The `ignore-scripts=true` rollout will break installs.** Affected packages include `husky`, `bcrypt`, `node-sass`, `puppeteer`, `playwright`, `cypress`, `esbuild`, `swc`, and anything using `node-gyp` for native compilation. See [`docs/breakage.md`](docs/breakage.md). Plan for a few days of Slack tickets after rollout. Document `npm install --foreground-scripts` for affected devs.

2. **Hosts file blocks are fragile.** Some VPN clients, security agents, and corporate DNS overlays rewrite `/etc/hosts`. Scripts are idempotent (use managed markers) so weekly re-runs restore state.

3. **The sensor is pull-based.** The TanStack wave hit production within ~16 hours of the malicious PR landing. Socket detected and flagged the artefacts within six minutes of publication. A daily sensor is forensic backstop, not real-time prevention.

4. **Tripwires create false-positive risk in any other scanner.** Other security tools may flag the tripwire `setup.mjs` files as suspicious. The bundled sensor knows to skip files containing the "Workspace ONE tripwire" marker string.

5. **The Session/Oxen exfil channel cannot be blocked at DNS.** It's a fully E2E-encrypted dead-drop with no central C2. The hosts-file block on seed nodes makes initial bootstrap harder but isn't a hard block.

6. **Credential rotation is not automated.** Deliberately. Wrong-order rotation can trigger the dead-man's switch. The remediate script disables the switch first and logs everything for the IR team, then humans make the rotation calls.

7. **IOC lists drift.** This repo's IOCs are accurate as of the May 11–13 2026 TanStack wave (CVE-2026-45321). Subsequent waves will introduce new payload filenames, C2 domains, and persistence paths. See [`docs/iocs.md`](docs/iocs.md) for the current list and update process.

---

## Contributing

Issues and PRs welcome, especially:

- **New IOCs** from subsequent waves — file an issue with source links
- **Additional persistence paths** (this campaign has expanded persistence locations with every wave)
- **Coverage for Linux endpoints** managed via Workspace ONE — not currently in scope but the same patterns apply
- **Hardening improvements** to the prevent scripts that don't break legitimate dev workflows

Please do not file issues containing live malicious package versions, payload hashes that could enable retrieval of live malware, or anything else that helps the attacker.

---

## License

MIT — see [LICENSE](LICENSE).

This is unofficial community tooling. It is not endorsed by Omnissa, Anthropic, or any other vendor named in the code. Test in a lab environment before deploying to production endpoints. The author accepts no liability for damage caused by deployment, including but not limited to broken `npm install` flows, support-ticket surges, and chronic eye-rolling from your developer population.
