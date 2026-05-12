# Threat Model — What This Catches and What It Doesn't

A deliberately honest assessment. The point of this document is to make sure deployers understand the scope so they can put complementary controls in place.

## Assumptions

- Endpoints are managed by Workspace ONE UEM with sensor and script capability
- Developer machines run npm/pnpm/yarn against the public npm registry (with or without a proxy)
- Developers have admin / sudo rights on their machines (typical for engineering populations)
- The Workspace ONE Hub agent has the privilege to run scripts in System context and read sensor output in User context

## Adversary capabilities (per current waves)

The Mini Shai-Hulud / TeamPCP adversary is, observably:

- **Sophisticated:** chains GitHub Actions vulnerabilities (cache poisoning + memory extraction), achieves valid SLSA Build Level 3 provenance on malicious artefacts, uses Bun specifically to evade Node.js monitoring
- **Patient:** poisoning runs persist for hours before triggering
- **Adaptive:** new payload filenames, new C2 domains, and new persistence locations appear each wave
- **Operationally cautious:** geofences out Russian-locale systems, has a destructive geofence for Israel/Iran (1-in-6 chance of `rm -rf /`)
- **Not infinite:** relies on the npm lifecycle hook to bootstrap, uses well-known persistence locations, depends on specific C2 domains for at least some exfil channels

The asymmetry the defender exploits: the bootstrap method is constrained, and the persistence locations are visible.

## What this repo catches

### High confidence

- **Already-infected machines** — sensor returns `STATUS:DETECTED` on dropped payload files, dead-man's-switch LaunchAgents, and lock files. Near-zero false positives on these IOCs.
- **Future infections via the same bootstrap (`preinstall` hook)** — prevent script's `ignore-scripts=true` makes this fail silently.
- **Repository-based infections** — when an infected repo is cloned, the sensor scans per-repo `.claude/` and `.vscode/` directories and flags the contents.

### Medium confidence

- **Sanitised settings/tasks files** — the sensor's regex matches current known IOCs. New campaigns will introduce new strings; sensor regex needs updating per wave.
- **C2 exfiltration to known infrastructure** — hosts file blocks `git-tanstack.com`, Session seed nodes, etc. But:
  - Session/Oxen is E2E with a peer-to-peer network — seed blocks make bootstrap harder but aren't a hard block
  - GitHub commit-search dead-drops cannot be blocked at DNS (it's just `api.github.com`)
  - The worm has a "C2 resurrection" mechanism that searches GitHub for new infrastructure markers (`FIRESCALE`)

### Low confidence

- **Future variants using new bootstrap paths** — e.g., a wave that targets `pip install` Python lifecycle hooks instead of npm `preinstall`. The PyPI `lightning` wave did exactly this, executing on `import`, not install. Our endpoint controls don't cover that path.
- **OIDC token theft from CI** — the TanStack wave didn't steal npm tokens at all; it extracted GitHub Actions OIDC tokens from runner process memory. Endpoint controls can't help here.

## What this repo doesn't catch

### Out of scope by design

- **Registry-level prevention** — should be a registry proxy with allowlisting / scanner
- **CI/CD pipeline hardening** — SHA-pinned actions, OIDC trust review, `pull_request_target` audit
- **Credential rotation** — humans-in-the-loop required
- **Cooldown windows on package versions** — needs registry tooling
- **Repository hygiene** — `.npmrc` audits, lockfile enforcement, dependency review

### Currently unsupported

- **WSL on Windows** — if devs use WSL Ubuntu and `npm install` there, neither the Windows nor Linux endpoint controls apply unless the WSL distro is itself WS1-enrolled (uncommon). The npm config inside WSL is independent.
- **GitHub Codespaces / cloud dev environments** — not a managed endpoint.
- **Docker dev containers** — same story.
- **Linux distros outside Ubuntu/Debian/RHEL** — the Linux scripts assume `getent passwd`, systemd, and `chattr`. Tested on Ubuntu 22.04/24.04, RHEL 9, Debian 12. Other distros likely work but may need adjustment.

### Gaps the adversary could exploit

- **A new payload filename we haven't added to the IOC list.** Sensor wouldn't flag `STATUS:DETECTED`, only `STATUS:SUSPECT` (and only if the config file references known strings). Closing this gap requires either rapid IOC updates or a structural change — e.g., flagging *any* file in `~/.claude/` or `~/.vscode/` that isn't on an allowlist, which would generate noise from legitimate Claude Code hooks.
- **Persistence via a path we don't scan.** Current scope is `.claude/` and `.vscode/`. Possible extensions: `.cursor/`, `.windsurf/`, `.continue/`, `.codeium/`, shell rc files, git templateDir, npm `init-module`. The next variant will probably target one of these.
- **Disabling the prevent script's effects.** A privileged user can `npm config set ignore-scripts false --location=user` and undo the protection for themselves. The sensor doesn't check for this. If you want to enforce, audit user-scope npmrcs in a separate sensor.

## Defence in depth — what to layer on top

If this repo is the only thing standing between your developer population and the next wave, you're under-protected. The full stack should include:

1. **Registry proxy with allowlisting** (Sonatype Nexus, JFrog Artifactory)
2. **Scanner in CI** (Socket, Snyk, Sonatype IQ, JFrog Xray) — catches malicious packages before install
3. **Cooldown windows** on new package versions (StepSecurity Harden-Runner, custom registry rules)
4. **SHA-pinned GitHub Actions** in your own workflows, automated via `pin-github-action`
5. **OIDC trust audit** — review `permissions: id-token: write` workflows, ensure `aud` claim is constrained
6. **Endpoint controls** (this repo)
7. **EDR/XDR with behavioural detection** — picks up the dropper's network activity even if signature-based blocks miss

This repo is layer 6. Layers 1–4 are doing the heavy lifting.

## Honest expectations

- **First infection caught:** highly likely the sensor will catch any already-compromised dev machine on first scan.
- **Future waves blocked:** likely for any wave that uses the same `preinstall`-based bootstrap. Unlikely for waves that switch entry vectors (import-time execution, CI memory extraction).
- **Coverage rate:** if your dev population is fully enrolled and scripts have run, expect ~70% coverage of the current threat surface. The other 30% requires the registry/CI controls above.
- **Maintenance burden:** budget half a day per major wave to update IOCs and test. Realistically, this means roughly monthly updates given current campaign tempo.
