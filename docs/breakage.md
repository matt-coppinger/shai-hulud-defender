# Breakage Notes — `ignore-scripts=true`

This document lists the npm packages and dev workflows that **will break** when the prevent script sets `ignore-scripts=true` machine-wide, and the workarounds.

## Why this trade-off

`ignore-scripts=true` is the single highest-impact control against current Shai-Hulud waves. Every current variant relies on the npm `preinstall` (or git-dep `prepare`) lifecycle script firing. Disabling lifecycle scripts globally neutralises that entire vector.

But it also breaks legitimate packages that use `postinstall` for things like:
- Compiling native bindings (`node-gyp`)
- Downloading browser binaries (Puppeteer, Playwright, Cypress)
- Setting up git hooks (Husky)
- Native module prebuilds (`@swc/core`, `esbuild`)

## Affected packages (non-exhaustive)

### Git hooks
- `husky` — needs `husky install` to set up git hooks. Workaround: run `npx husky install` manually after `npm install`.
- `simple-git-hooks`
- `lefthook`

### Native modules requiring `node-gyp`
- `bcrypt`, `bcryptjs` (jsversion doesn't need scripts)
- `sqlite3`, `better-sqlite3`
- `node-sass` (replaced by `sass-embedded` in most projects; `sass` (Dart Sass) doesn't need scripts)
- `canvas`
- `sharp` (newer versions ship prebuilt binaries via `optionalDependencies`, but still benefits from postinstall in some envs)
- `node-pty`
- `serialport`

### Browser/runtime binary downloads
- `puppeteer` — downloads Chromium. Workaround: `npm install puppeteer --foreground-scripts`, or use `puppeteer-core` + system Chrome.
- `playwright` — downloads browsers. Workaround: `npx playwright install` after install.
- `cypress` — downloads test runner binary. Workaround: `npm install cypress --foreground-scripts`, or set `CYPRESS_INSTALL_BINARY=0` and use system Cypress.
- `chromedriver`, `geckodriver`, `electron`

### Native build tooling
- `esbuild` — usually has prebuilt binaries via optional deps, but postinstall sets symlinks
- `swc`, `@swc/core`
- `turbo`, `nx` (some versions)
- `rollup` (some plugins)

### Other
- Any tool using `node-pre-gyp` or `prebuild-install` will likely fail without `postinstall`
- `core-js` has a postinstall that prints donation messages — harmless, won't break anything

## Escape hatches

### Per-install override
```bash
npm install --foreground-scripts <pkg>
npm install --foreground-scripts   # for all deps in current package.json
```

### Per-repo override (creates `.npmrc` in repo root)
```bash
echo "ignore-scripts=false" > .npmrc
```

This is **convenient but risky** — committing `.npmrc` with `ignore-scripts=false` means future supply-chain attacks against any dep in that repo will execute scripts. Only do this for repos with strict dependency control (e.g., everything locked to specific versions in `package-lock.json`, dependabot reviews enforced).

### Per-user override (overrides machine config)
```bash
npm config set ignore-scripts false --location=user
```

Devs who hit constant friction may want this. The trade-off: their machine is back to the default exposure. Recommend only for devs who genuinely cannot work without scripts and understand the risk.

### Yarn-specific

```bash
# Berry
yarn config set enableScripts true

# Classic
yarn install --ignore-scripts=false
```

## Detecting which packages need scripts in a given repo

```bash
# Lists all dependencies with lifecycle hooks
npm ls --all --json | jq -r '
  .. | objects | select(.scripts) | select(.scripts | keys | any(. == "preinstall" or . == "postinstall" or . == "install" or . == "prepare")) | .name
'
```

Or, more pragmatic: run `npm install` with prevent active, see what breaks, document the affected packages for your developer comms.

## Communication strategy for rollout

Three-phase comms work well:

1. **T-7 days:** Announce in #dev-general. Explain the threat, the control, the breakage. Link this doc.
2. **T-1 day:** Reminder + on-call rota for support.
3. **T-0:** Deploy via Workspace ONE. Be on Slack for the first 2 hours.

Expected support volume: 1–3 tickets per 100 developers on day one, dropping to near-zero by day three as devs internalise the `--foreground-scripts` flag.

## Common false alarms

- **"My CI is broken"** — CI runs in containers / fresh VMs that don't have the machine-wide `npmrc`. This is correct behaviour. CI should have its own controls (Socket / Snyk in pipeline, registry proxy).
- **"My local install fails but I don't see why"** — `npm install --verbose --foreground-scripts` will show which package needed the script.
- **"It works on my machine but not my colleague's"** — likely your colleague's machine has the prevent script and yours doesn't yet. Check `Get-ItemProperty HKLM:\SOFTWARE\Omnissa\ShaiHuludPrevent` (Windows) or the `/Library/Preferences/com.omnissa.shai_hulud_prevent.plist` (macOS).
