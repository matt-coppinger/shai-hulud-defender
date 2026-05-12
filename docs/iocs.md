# Indicators of Compromise (IOCs)

Current as of the **May 11–12, 2026 TanStack wave**. Update process: when a new wave is reported, add the new IOCs here, update the `$payloadFiles` / `$blockDomains` arrays in `scripts/`, and update the regex in `sensors/`.

---

## Payload filenames

Dropped to `~/.claude/`, `~/.vscode/`, and per-repo `.claude/` / `.vscode/` directories:

- `setup.mjs` — Bun dropper (cleartext, ~204 lines, downloads Bun v1.3.13 then executes payload)
- `router_runtime.js` — obfuscated credential stealer (~2.3 MB, obfuscator.io output)
- `router_init.js` — same as router_runtime, used in TanStack wave
- `execution.js` — SAP wave variant (~11 MB)
- `tanstack_runner.js` — TanStack wave variant

## Persistence locations

| Location | Purpose |
|---|---|
| `~/.claude/settings.json` | SessionStart hook re-runs payload when Claude Code opens |
| `~/.claude/settings.local.json` | Per-project variant of above |
| `~/.vscode/tasks.json` | `folderOpen` trigger re-runs payload when VS Code opens repo |
| `<repo>/.claude/settings.json` | Repo-level variant — turns the repo itself into the infection vector |
| `<repo>/.vscode/tasks.json` | Same, for VS Code |

## Dead-man's switch

| File | Platform |
|---|---|
| `~/Library/LaunchAgents/com.user.gh-token-monitor.plist` | macOS |
| `~/Library/LaunchAgents/*gh-token-monitor*.plist` | macOS (variants) |
| `~/.config/systemd/user/gh-token-monitor.service` | Linux |
| `~/.local/bin/gh-token-monitor.sh` | Linux/macOS helper |
| `~/.config/gh-token-monitor/` | Config directory |

Behaviour: polls `api.github.com/user` every 60 seconds with stolen token. On HTTP 40x, executes `rm -rf ~/`. TTL 24 hours.

## Lock files (anti-double-execution)

- `/tmp/tmp.987654321.lock` — SAP / earlier waves
- `/tmp/tmp.ts018051808.lock` — TanStack wave
- `%TEMP%\tmp.987654321.lock` — Windows equivalent
- `%TEMP%\tmp.ts018051808.lock` — Windows TanStack variant

## C2 / payload-fetch infrastructure

| Indicator | Type | Notes |
|---|---|---|
| `git-tanstack.com` | Domain | Primary HTTPS exfil + PyPI second-stage download |
| `api.cloud-aws.adc-e.uk` | Domain | SAP wave custom AWS SDK partition redirect |
| `filev2.getsession.org` | Domain | Session/Oxen file upload network |
| `seed1.getsession.org`, `seed2.getsession.org`, `seed3.getsession.org` | Domain | Session network bootstrap seeds |
| `api.masscan.cloud` | Domain | Observed in TanStack wave |
| `83.142.209.194` | IP | PyPI `mistralai==2.4.6` second-stage download (`transformers.pyz`) |

## String IOCs (for content scanning)

These strings appear in payload files, config files written by the payload, and attacker-controlled GitHub repos:

- `EveryBoiWeBuildIsAWormyBoi` — campaign internal name, used as GitHub commit-search marker
- `A Mini Shai-Hulud has Appeared` — repo description on attacker-controlled exfil repos (April 2026 wave)
- `Shai-Hulud: Here We Go Again` — repo description (May 2026 wave)
- `IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner` — npm token description string created by the worm
- `voicproducoes` — GitHub username that authored malicious commits in TanStack wave
- `thebeautifulmarchoftime`, `thebeautifulsandsoftime` — TanStack-specific C2 beacon tokens
- `FIRESCALE` — marker for C2 resurrection via GitHub commit search

## Known payload hashes

> Hashes drift between waves; use filename + path matching as primary signal.

- `ab4fcadaec49c03278063dd269ea5eef82d24f2124a8e15d7b90f2fa8601266c` — `router_init.js` (TanStack wave, May 11)

## Campaign branch-name signatures

GitHub branches created by the worm follow this pattern: `dependabot/github_actions/format/<dune-word>`

Where `<dune-word>` is drawn from: `sietch`, `sardaukar`, `atreides`, `shai-hulud`, etc. The `dependabot/` prefix is deliberate camouflage.

## Compromised packages (May 2026 wave — partial list)

Refer to vendor reports for the live list — packages are being added hourly during active waves.

Major scopes affected:
- `@tanstack/*` — 42 packages, 84 versions
- `@uipath/*` — multiple including `@uipath/apollo-core`
- `@mistralai/mistralai` — npm AND PyPI
- `@opensearch-project/*`
- `guardrails-ai` (PyPI) — executes on import
- `lightning` 2.6.2/2.6.3 (PyPI)
- `mbt@1.2.48`, `@cap-js/sqlite@2.2.2`, `@cap-js/postgres@2.2.2`, `@cap-js/db-service@2.10.1` (April SAP wave)
- `intercom-client@7.0.4`

## Sources

- [Mend — Mini Shai-Hulud Is Back](https://www.mend.io/blog/mini-shai-hulud-is-back-172-npm-and-pypi-packages-compromised-in-latest-wave/)
- [Socket — TanStack Compromise](https://socket.dev/blog/tanstack-npm-packages-compromised-mini-shai-hulud-supply-chain-attack)
- [Wiz — TanStack Analysis](https://www.wiz.io/blog/mini-shai-hulud-strikes-again-tanstack-more-npm-packages-compromised)
- [Endor Labs — SAP Wave](https://www.endorlabs.com/learn/mini-shai-hulud-npm-worm-hits-sap-developer-packages)
- [Snyk — TanStack](https://snyk.io/blog/tanstack-npm-packages-compromised/)
- [StepSecurity — Attribution to TeamPCP](https://www.stepsecurity.io/blog/mini-shai-hulud-is-back-a-self-spreading-supply-chain-attack-hits-the-npm-ecosystem)
- [Semgrep — PyTorch Lightning](https://semgrep.dev/blog/2026/malicious-dependency-in-pytorch-lightning-used-for-ai-training/)
- [Upwind — Deobfuscated Analysis](https://www.upwind.io/feed/shai-hulud-tanstack-supply-chain-worm)
