# Linux Deployment Notes

Linux support tested on **Ubuntu 22.04, Ubuntu 24.04, RHEL 9, Debian 12**. Other distros likely work but may need tweaks.

## Linux-specific differences from macOS

| Concern | macOS | Linux |
|---|---|---|
| Persistence service | LaunchAgent (`~/Library/LaunchAgents/*.plist`) | systemd user unit (`~/.config/systemd/user/*.service`) |
| Service unload | `launchctl bootout gui/$uid` | `systemctl --user stop` (requires user's systemd session) |
| Immutable flag | `chflags uchg` | `chattr +i` (ext4/xfs/btrfs only; no-op on tmpfs/overlay) |
| User enumeration | `dscl . -list /Users` | `getent passwd` |
| Min real UID | 500 | varies — 500 on RHEL, 1000 on Ubuntu/Debian. Script accepts ≥500. |
| DNS cache flush | `dscacheutil -flushcache` | `resolvectl flush-caches` or `systemd-resolve --flush-caches` |
| Sensor triggers | Periodic + event | **Periodic only** |

## Workspace ONE Linux constraints

**Linux sensors are schedule-only.** Workspace ONE Hub for Linux does not support event-based sensor triggers (no login/logout/startup events). The sensor runs on the Intelligent Hub sample schedule — typically every 4 hours, configurable per-tenant.

This means the detection latency on Linux is higher than on Windows/macOS. If your dev population is primarily Linux, consider tightening the Hub sample schedule, or layer EDR (CrowdStrike, SentinelOne) for real-time process monitoring on top.

## systemctl --user nuances

The remediate script needs to stop systemd user units in the user's context, not the system one. This requires:

1. `XDG_RUNTIME_DIR=/run/user/<uid>` to be set
2. The user to have an active systemd session (`/run/user/<uid>` exists)
3. `runuser -u <user> -- systemctl --user ...` to execute in their context

If the user is not logged in at the moment of remediation, the script can't stop the running service — but it can still quarantine the unit file so it won't start on next login. The dead-man's switch is mid-poll though, so prioritise getting the user to log out → remediate → log back in.

For server use cases where users don't typically have a login session, consider `loginctl enable-linger <user>` so the systemd user instance runs without a login — but be aware this also means the worm's service runs without a login, which is worse.

## chattr filesystem support

`chattr +i` (immutable flag) works on:
- ext2/ext3/ext4
- xfs
- btrfs (since kernel 5.x with limitations)
- f2fs

Does **not** work on:
- tmpfs (most `/tmp` mounts)
- overlay (containers)
- NFS, CIFS network mounts
- FAT, exFAT

If a developer's home directory is on a network mount, the tripwire's immutable flag will be a no-op. The file will still exist and be read-only via permissions, but a determined dropper can overwrite it. The `ignore-scripts=true` control is doing the real work — tripwires are belt-and-braces.

## Distros known to need tweaks

- **Alpine** — uses musl libc, busybox utilities. `chattr` may not be installed by default (`apk add e2fsprogs-extra`). The Bash regex syntax used should still work.
- **NixOS** — `/etc/hosts` and `/etc/npmrc` are managed by the Nix store and reverted on rebuild. You'd need to manage these via your Nix config instead.
- **Slackware, Gentoo** — likely fine but untested.

## Verification commands

After prevent has run:

```bash
# npmrc
cat /etc/npmrc

# Hosts block
grep -A 20 shai_hulud_prevent /etc/hosts

# Marker
cat /var/lib/omnissa/shai_hulud_prevent.state

# Tripwires (for a specific user)
ls -la /home/<user>/.claude/setup.mjs
lsattr /home/<user>/.claude/setup.mjs   # should show 'i' attribute
```

After remediate has run:

```bash
# Quarantine contents
ls /var/log/omnissa/shai_hulud/quarantine/*/

# Remediate log
tail /var/log/omnissa/shai_hulud/remediate.log

# Confirm no active gh-token-monitor
systemctl --user --all | grep gh-token-monitor    # should be empty or show 'not-found'
```

## Container / WSL caveat

If developers use Linux **inside containers or WSL2** without those being Workspace ONE-enrolled, these controls don't apply inside the container. The host's `/etc/npmrc` does not propagate into containers unless explicitly mounted.

Mitigations:
1. Distribute a hardened base image with `ignore-scripts=true` baked in
2. Document in your dev onboarding that container/WSL environments need the same `npm config set ignore-scripts true --location=user` applied manually
3. If you're brave: have CI inject `.npmrc` into dev container builds
