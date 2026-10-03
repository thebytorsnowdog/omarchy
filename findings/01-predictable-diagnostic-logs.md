# Predictable world-readable diagnostic logs disclose local system information

## Affected files and lines

- `bin/omarchy-debug`, lines 29 and 37-61 (fixed `/tmp` destination and diagnostic collection), with upload at lines 77-78.
- `bin/omarchy-upload-log`, lines 8-9 and 24-39 (two fixed `/tmp` destinations), with journal collection at lines 98-114 and upload at line 155.

## Vulnerable code

```bash
# bin/omarchy-debug
LOG_FILE="/tmp/omarchy-debug.log"
...
cat > "$LOG_FILE" <<EOF
...
$(inxi -Farz)
...
$DMESG_OUTPUT
...
$(journalctl -b -p 4..1)
EOF
```

```bash
# bin/omarchy-upload-log
TEMP_LOG="/tmp/upload-log.txt"
SYSTEM_INFO="/tmp/system-info.txt"
...
cat "$SYSTEM_INFO" >"$TEMP_LOG"
journalctl -b 0 >>"$TEMP_LOG" 2>/dev/null
```

Neither command applies a restrictive umask or mode. On a normal `umask 022` desktop, shell redirection creates these files as mode `0644` in the shared `/tmp` directory. They are not removed after use.

## Why this is exploitable

**Attacker position:** an unprivileged local account on the same multi-user Omarchy machine.

**Preconditions:** the victim runs `omarchy debug` or `omarchy-upload-log`; the attacker can traverse `/tmp`, as is normal. No race is required. Once the victim creates the file, the attacker can read it by its constant public name. The files can contain hardware and network inventory, kernel messages (the debug command obtains `dmesg` through `sudo`), current or previous boot journal entries, hostname, and the complete installed-package inventory. Journal and kernel messages can contain device identifiers, local usernames and paths, network metadata, crash diagnostics, and command/service error text that was not intended for another local account.

Linux's protected-symlink and protected-regular-file sysctls mitigate common cross-user overwrite variants in a sticky `/tmp`, but they do not prevent reading a victim-owned `0644` file. Therefore this report does not rely on a symlink race.

## Impact

A local user can silently collect another user's privileged and session diagnostic output. The direct impact is cross-account confidentiality loss; the exposed inventory and error information can also improve follow-on local attacks. The file persists until cleanup or reboot, widening the observation window.

## Suggested CVSS 4.0 vector

`CVSS:4.0/AV:L/AC:L/AT:P/PR:L/UI:P/VC:L/VI:N/VA:N/SC:N/SI:N/SA:N`

Rationale: the attacker needs a local account, the victim must invoke a diagnostic command, and only confidentiality is directly affected.

## Minimal safe proof of concept

Run this in a throwaway Arch VM or container from the repository root. It avoids privileged collection while exercising the real output path:

```bash
rm -f /tmp/omarchy-debug.log
umask 022
bash bin/omarchy-debug --no-sudo --print >/dev/null 2>&1 || true
stat -c 'mode=%a owner=%U path=%n' /tmp/omarchy-debug.log
head -n 5 /tmp/omarchy-debug.log
```

The expected mode is `644`; a second local account can read the same path. To demonstrate the second command's creation behavior without uploading anything, the equivalent primitive is:

```bash
rm -f /tmp/upload-log.txt /tmp/system-info.txt
umask 022
(printf 'simulated journal secret\n' > /tmp/upload-log.txt)
stat -c '%a %n' /tmp/upload-log.txt
```

Do not invoke the upload action for this test.

## Suggested fix

Create a private temporary directory with `mktemp -d` after setting `umask 077`, write all diagnostic artifacts beneath it, and remove it with an `EXIT` trap. For example:

```bash
umask 077
work_dir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/omarchy-diagnostics.XXXXXX") || exit 1
trap 'rm -rf -- "$work_dir"' EXIT
LOG_FILE="$work_dir/debug.log"
```

When `XDG_RUNTIME_DIR` exists and is owned by the current user, prefer it over `/tmp`. If retaining a well-known convenience copy is desired, place it in a user-private state directory and explicitly install it with mode `0600`. Apply the same pattern to both `TEMP_LOG` and `SYSTEM_INFO`; upload directly from the private file.
