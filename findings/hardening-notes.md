# Hardening notes

These items match the audit's search criteria but do not have a sufficiently realistic attacker path for separate vulnerability reports.

## Remote installer scripts and binaries are executed without pinned integrity

`bin/omarchy-install-dev-env` downloads and immediately executes the current uv, rustup, and opam installer scripts at lines 73, 95, and 108. `bin/omarchy-install-gaming-geforce-now` downloads the current NVIDIA installer into `/tmp` and executes it at lines 11-16. `bin/omarchy-upgrade-to-quattro` streams the current `master` branch archive into `tar` at lines 964-970 when no local checkout is available.

All observed transport URLs are HTTPS, and these optional commands run with the invoking user's explicit intent. Exploitation therefore requires compromise of TLS, DNS plus trust, the upstream hosting account/CDN, or the upstream artifact itself; that is a supply-chain hardening concern rather than a source-tree vulnerability by itself. Pin immutable versions and SHA-256 digests (or verify an upstream signature whose key is pinned in the distribution) before execution. Download into a mode-0700 private directory rather than a fixed `/tmp/GeForceNOWSetup.bin` path.

## The installer log is deliberately world-writable

`install/helpers/logging.sh` creates the configured installation log and applies `chmod 666` at lines 13-17. The default system and hardware entrypoints select `/var/log/omarchy-install.log`. This permits any local account to append misleading content after installation and makes the log readable even if it later gains sensitive diagnostics. The containing `/var/log` directory normally prevents an unprivileged account from replacing or unlinking the root-owned inode, and installation generally occurs before untrusted local accounts exist, so no credible privilege escalation was established.

Use root ownership and mode `0600` (or a dedicated group and `0640`). If both root-scoped and user-scoped setup must append, use journald, a privileged logging helper, or separate per-user logs rather than a shared `0666` file.

## Optional development databases use intentionally weak local credentials

`bin/omarchy-install-docker-dbs` lines 18-23 starts optional databases with empty passwords, PostgreSQL trust authentication, or documented default passwords. Every published port is explicitly bound to `127.0.0.1`, and installation requires an interactive user choice, so this is not remotely exploitable by default. A malicious process already executing as the desktop user could access the databases, but it generally already has equivalent access to that user's development data.

Generate random credentials, display them once, and store them mode `0600`; at minimum warn that all local processes can authenticate. Consider Unix sockets where supported.

## systemd-resolved listens additionally on the Docker bridge

`etc/systemd/resolved.conf.d/20-docker-dns.conf` sets `DNSStubListenerExtra=172.17.0.1`. This exposes the host resolver to local Docker containers by design, not to external interfaces. No direct privilege boundary bypass was found, but deployments running hostile containers should consider whether they require host DNS and firewall the listener to the intended bridge.

## Auto-accept Bluetooth agent depends on scan-window gating

`default/systemd/user/bt-agent.service` runs `bt-agent -c NoInputNoOutput` at line 18. The adjacent comments document that BlueZ is pairable only while the user has explicitly opened the Bluetooth panel and initiated scanning. This creates a short consent window rather than unattended always-pairable behavior, so it was not treated as a vulnerability. A confirmation-capable agent would nevertheless reduce opportunistic nearby pairing risk.

## Review coverage and negative results

The audit inventoried all 938 regular files under `install/`, `migrations/`, `bin/`, `config/`, and `default/`, and separately reviewed systemd-related files under `etc/`. Broad searches covered signature policy, package-manager invocation, downloads and URLs, temporary paths, permissions and ownership, privilege elevation, shell evaluation, listeners, authentication settings, and Bluetooth settings. Shell syntax validation covered every regular file in `bin/`, `install/`, and `migrations/` that Bash could parse.

No additional actionable issue was established. In particular:

- The known `install/hardware/pacman.sh` `SigLevel = Never` issue and the known `bin/omarchy-upgrade-to-quattro` `Optional TrustAll` re-run issue were excluded as requested.
- Current Omarchy repository configs use `SigLevel = Required DatabaseOptional`; migration `1787589206.sh` removes a legacy permissive override.
- No non-loopback HTTP download was found. Plain HTTP occurrences were loopback web interfaces, SVG namespace identifiers, documentation, or accepted user-supplied web-app URLs.
- Package installation uses pacman repository signatures; `--noconfirm` alone does not disable signature verification. AUR operations use the normal build tooling and no source-level signature bypass was found.
- Privileged migrations with sensitive replacements generally use root-created same-directory temporary files and atomic renames. The reviewed migrations either test prior state or make convergent edits; no repeatable interruption path that leaves a new insecure state was demonstrated.
- No default externally reachable application service was found in the scoped units. Optional Sunshine rules are limited to private CIDRs and Tailscale; optional development databases bind loopback.
