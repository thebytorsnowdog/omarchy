# Security audit of the code this fork ships

The repository default branch is `quattro` (`origin/HEAD` points at `origin/quattro`). This audit is of that tree, at `a85e29abb556816f4644cf975e98da694b486aa8`.

That commit is an ancestor of `quattro` on `github.com/omacom/omarchy` (`573b518be16ec47547d50fe6197bc7f53e982340`). The fork is 722 commits behind that upstream tip and 0 commits ahead. `git log quattro --author=thebytorsnowdog` is empty, so the default branch contains no commit authored as Ian Dunsmore, Donald Dunsmore, or Snowy. Commits under those names exist on other remote branches and are not in the tree this fork publishes. The issues below are in the snapshot the fork ships. The same lines are still present on the upstream tip fetched for this comparison, so they are not a private patch on top of upstream, and they are not something a later upstream commit has already removed.

No CVE or GHSA identifier is claimed. None was confirmed against this tree.

## Confirmed issues

### Config refresh accepts a path that leaves ~/.config

`bin/omarchy-refresh-config` takes one relative path and appends it to both `~/.config` and `$OMARCHY_PATH/config`. It then checks `[[ -e ]]` on the source. A `..` component is a real path. The two prefixes are not the same depth, so the destination can fall outside `~/.config` while the source still exists. Callers in the tree pass fixed relative paths. The command itself is the boundary: anything that can pass the argument, including a person at the shell, can aim the copy.

Evidence: `bin/omarchy-refresh-config` as shipped, and `bash test/shell.d/refresh-config-test.sh` before the fix (a path `../outside/note` whose source existed was accepted). `AGENTS.md` already describes this resolution.

Fix: draft pull request https://github.com/thebytorsnowdog/omarchy/pull/2

### Sunshine Admin disables certificate checks for the browser process

`bin/omarchy-install-service-sunshine` sets the admin launcher to `omarchy-launch-webapp https://localhost:47990 --ignore-certificate-errors` and passes that string to `omarchy-webapp-install` as the desktop `Exec` line. `bin/omarchy-launch-webapp` forwards every argument after the URL to the browser (`--app=` plus `"${@:2}"`), either through `bin/omarchy-cmd-browser-handoff` or by starting the browser. That switch is not scoped to `localhost:47990`. A launch that starts the browser process disables certificate error handling for every site that process loads. The desktop file keeps the switch, so the behaviour is not limited to the install command.

Evidence: those three scripts, read in this tree. The self-signed admin page can still be opened. The browser's own warning is limited to that origin.

Fix: draft pull request https://github.com/thebytorsnowdog/omarchy/pull/7

### A repeated quattro upgrade leaves Optional TrustAll in place

`bin/omarchy-upgrade-to-quattro` function `configure_pacman_channel` always rewrites the `[omarchy]` section with `SigLevel = Optional TrustAll` (the `awk` block around the `print "SigLevel = Optional TrustAll"` lines). That lets the packaging key install before signatures are required. `migrations/1787589206.sh` deletes the line once, after the key `40DFB630FF42BCFFB047046CF0134EE680CAC571` is present. Migrations are recorded per user and do not run twice. The upgrade script tells the operator that re-running is safe. A re-run writes `TrustAll` again, `run_post_upgrade_migrations` skips the old migration, and `pacman` keeps accepting unsigned packages from `[omarchy]` after the script exits.

Evidence: `configure_pacman_channel`, the call order `run_final_system_package_upgrade` then `run_post_upgrade_migrations` near the end of the script, and `migrations/1787589206.sh`.

Fix: draft pull request https://github.com/thebytorsnowdog/omarchy/pull/4

### The AUR installer keeps a sudo timestamp while PKGBUILDs run

`bin/omarchy-pkg-aur-install` sourced `bin/omarchy-sudo-keepalive` and then ran `yay`. The keepalive runs `sudo -v` and refreshes the timestamp every 60 seconds. A PKGBUILD is third-party shell. With a live timestamp it can invoke `sudo` and get root without another prompt. `bin/omarchy-update` already treats this as a boundary: it revokes the timestamp and places `default/omarchy/sudo-no-update/sudo` (which execs `/usr/bin/sudo -N`) on `PATH` before `bin/omarchy-update-aur-pkgs`.

Evidence: `bin/omarchy-pkg-aur-install`, `bin/omarchy-sudo-keepalive`, the AUR block at the end of `bin/omarchy-update`, `bin/omarchy-update-aur-pkgs`, and `default/omarchy/sudo-no-update/sudo`.

`bin/omarchy-pkg-install` still sources the keepalive. It installs repository packages through `pacman`, which is already a root transaction, so that call was left as it is.

Fix: draft pull request https://github.com/thebytorsnowdog/omarchy/pull/3

### SSH setup listens before a key is authorised

`bin/omarchy-setup-security-sshd` called `setup_sshd` and `open_firewall` before `authorize_key` or the GitHub fetch, and only then `disable_password_auth`. Until that last step, `sshd` is running and port 22 is allowed while password authentication is still the effective setting. The interactive `gum` prompt sits inside that window. `install/config/firewall.sh` sets `ufw default deny incoming`, so the firewall rule is what makes the port reachable on a normal Omarchy install. Opening it early is the exposure.

Evidence: the function order at the bottom of `bin/omarchy-setup-security-sshd`, `disable_password_auth` writing `PasswordAuthentication no` only after a key exists, and the `ufw default deny incoming` line in `install/config/firewall.sh`.

Fix: draft pull request https://github.com/thebytorsnowdog/omarchy/pull/5

### Diagnostic logs are created world-readable under /tmp

`bin/omarchy-debug` writes `/tmp/omarchy-debug.log` with `cat >` and no `umask` change. `bin/omarchy-upload-log` does the same for `/tmp/upload-log.txt` and `/tmp/system-info.txt`. Neither command removes the files. Under umask 022 the shell creates them mode 0644. The debug file includes `inxi`, `sudo dmesg` unless `--no-sudo` is set, `journalctl -b -p 4..1`, and the package list. The upload command copies the install log or `journalctl` for this boot or the previous boot. Another local account can read those paths by name. This does not depend on winning a symlink race.

Evidence: both scripts, read in full for the output paths and the commands that fill them. A throwaway redirection with umask 022 creates mode 0644. The same redirection is what these commands use.

Fix: draft pull request https://github.com/thebytorsnowdog/omarchy/pull/6

## Left unchanged

### Apple T2 pacman repository is installed with SigLevel = Never

`install/hardware/pacman.sh` appends an `[arch-mact2]` repository when `lspci` shows PCI id `106b:1801` or `106b:1802`. The block sets `Server` to a GitHub release URL and `SigLevel = Never`. That disables signature checks for packages from that repository. It is a real weakening, and it is limited to that hardware match.

No fix was opened. This audit did not confirm that the mirror publishes signatures. Setting `Required` without a signed repository would stop pacman from installing those packages on the machines the block exists to support.

### The install log is mode 0666

`install/helpers/logging.sh` `start_install_log` runs `chmod 666` on `$OMARCHY_INSTALL_LOG_FILE` when logging is not forced to stdout. Any local account that can open the file can read it and append to it.

No fix was opened. The log is a shared file for the root install path and the user install path. `/var/log` is not writable by a normal user, so the inode cannot be replaced from there. No privilege escalation from the mode was demonstrated. A tighter mode needs a logging path that both writers can still use, which is a larger change than the defect shown here.

### Optional installers fetch and execute upstream scripts

`bin/omarchy-install-dev-env` pipes `https://astral.sh/uv/install.sh` to `sh`, runs `https://sh.rustup.rs` under `bash -c`, and runs `https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh` the same way. `bin/omarchy-install-gaming-geforce-now` downloads `GeForceNOWSetup.bin` with `curl -LO` into `/tmp` and executes that fixed name. The URLs are HTTPS. None of these commands records a digest.

No fix was opened. These run because the user asked for that toolchain or for GeForce NOW. Pinning a checksum that is not published in this tree would be a guess. The fixed `/tmp` name is unpleasant. It was not turned into a patch on its own, because the missing digest is the actual gap and there is nothing in the repository to pin.

### Docker's published-port default is unchanged

`etc/docker/daemon.json` sets the log driver, `dns`, and `bip`. It does not set `ip` or `com.docker.network.bridge.host_binding_ipv4`. Published container ports therefore follow Docker's own default, `0.0.0.0`.

No fix was opened. Binding every published port to `127.0.0.1` would change containers the user published for other machines. That is a product default, not a defect demonstrated in this tree.

### Development database containers use known local passwords

`bin/omarchy-install-docker-dbs` starts optional database containers with an empty MySQL or MariaDB root password, PostgreSQL `trust` authentication, MongoDB `admin` / `admin123`, and an MSSQL SA password of `@dmin123`. Every published port in that script is `127.0.0.1`.

No fix was opened. The command is an interactive choice for local development. A process that can connect already runs as the same user who can read that user's files. Replacing the passwords would be a behaviour change for every database this command creates, not a small repair of an accidental leak.

### omarchy-launch-or-focus evaluates the launch command

`bin/omarchy-launch-or-focus` runs `eval exec setsid $LAUNCH_COMMAND` when no matching window exists. The command is the caller's second argument. `default/hypr/helpers.lua` builds that argument with `shell_quote`. A search of `bin/`, `default/`, and `config/` did not find another caller that feeds it an unquoted string from outside the menu.

No fix was opened. Removing `eval` changes how launch strings with shell syntax are parsed, and no untrusted producer of that string was found.

## Checks

Each fix branch was tested on its own with the shell test named in its pull request. `test/shell.d/locate-test.sh` was syntax-checked only. `updatedb` is not installed in the environment used for this audit, and that file refuses to run without it. `bash test/shell.d/pkg-aur-install-sudo-test.sh` covers the sudo boundary the AUR change adds, including the `updatedb` arguments.
