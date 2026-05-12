# Security Policy

## Reporting a Vulnerability

If you find a security issue in this repository — a bypass in the detection logic, a way the prevent scripts fail open, a privilege escalation in the remediate scripts, or anything else that would reduce the protection these controls provide — please report it privately.

**Do not** open a public GitHub issue for security problems.

**Contact:** Use [GitHub's private security advisory](https://github.com/matt-coppinger/shai-hulud-defender/security/advisories/new) form for this repository.

### What to include

- A description of the issue and its impact
- Steps to reproduce, or a proof-of-concept
- Your assessment of severity (informational / low / medium / high / critical)
- Any suggested mitigation

### What to expect

This is a community project maintained on personal time. Realistic response times:

- **Acknowledgement:** within 5 working days
- **Initial assessment:** within 14 working days
- **Fix or disclosure decision:** within 30 working days for medium+ severity

For critical issues affecting active deployments, I'll prioritise. If the issue lets the worm bypass detection entirely, expect a same-day acknowledgement.

### Disclosure

Coordinated disclosure preferred. Once a fix is available and deployed, I'll credit you in the release notes unless you prefer to remain anonymous.

## What This Repository Is and Isn't

**This repository contains defensive tooling only.** It does not contain:

- Malware samples
- Exploit code
- Payload hashes that could be used to retrieve live malware
- Credentials, tokens, or other sensitive data
- Anything that helps an attacker

If you believe any file in this repository violates this principle, that itself is a security issue — please report it via the channel above.

## Threat Coverage Caveats

The [threat model document](docs/threat-model.md) is the honest assessment of what these controls catch and what they don't. Please read it before deploying. In particular:

- These are endpoint controls, not registry-level prevention
- IOC lists drift between campaign waves and require ongoing maintenance
- The Session/Oxen exfiltration channel cannot be blocked at DNS
- Credential rotation is not automated and remains a human responsibility

If you're deploying these scripts as your only defence against npm supply-chain attacks, you're under-protected. Layer them with a registry proxy, CI scanner, and EDR.

## Out of Scope

- Issues with the underlying Workspace ONE UEM product (report those to Omnissa)
- Issues with Claude Code, VS Code, npm, or any other third-party tool referenced in this repository (report to their respective vendors)
- Theoretical attacks that require capabilities beyond those documented for the Mini Shai-Hulud / TeamPCP campaign
- Issues only reproducible in unsupported environments (distros not listed in [linux-notes.md](docs/linux-notes.md), Workspace ONE versions older than 2210)

## Acknowledgements

Thanks in advance to anyone reporting issues responsibly. Public credit happens at the reporter's discretion.
