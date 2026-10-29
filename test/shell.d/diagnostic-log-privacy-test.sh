#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

runtime="$tmpdir/runtime"
stub_bin="$tmpdir/bin"
mkdir -p "$runtime" "$stub_bin" "$tmpdir/home"
chmod 700 "$runtime"

cat >"$stub_bin/inxi" <<'SH'
#!/bin/bash
dir=$(find "${XDG_RUNTIME_DIR:?}" -maxdepth 1 -type d -name 'omarchy-debug.*' -print -quit)
[[ -n $dir && -f $dir/debug.log ]] || exit 1
stat -c '%a' "$dir" >"${MODE_DIR:?}"
stat -c '%a' "$dir/debug.log" >"${MODE_FILE:?}"
printf '%s\n' "$dir" >"${LOG_PATH:?}"
printf 'inxi\n'
SH
for name in journalctl pacman expac comm hostname; do
  cat >"$stub_bin/$name" <<'SH'
#!/bin/bash
printf 'stub\n'
SH
done
chmod +x "$stub_bin"/*

rm -f /tmp/omarchy-debug.log
umask 022
MODE_DIR="$tmpdir/debug-dir-mode" MODE_FILE="$tmpdir/debug-file-mode" LOG_PATH="$tmpdir/debug-path" \
  XDG_RUNTIME_DIR="$runtime" HOME="$tmpdir/home" PATH="$stub_bin:$PATH" \
  bash "$ROOT/bin/omarchy-debug" --no-sudo --print >"$tmpdir/debug-out" 2>"$tmpdir/debug-err"

[[ ! -e /tmp/omarchy-debug.log ]] || fail "debug log is not written to the fixed /tmp path"
[[ $(cat "$tmpdir/debug-dir-mode") == 700 ]] ||
  fail "debug log directory is private" "$(cat "$tmpdir/debug-dir-mode")"
[[ $(cat "$tmpdir/debug-file-mode") == 600 ]] ||
  fail "debug log file is private" "$(cat "$tmpdir/debug-file-mode")"
[[ ! -e $(cat "$tmpdir/debug-path") ]] || fail "debug log directory is removed on exit"
grep -Fq 'SYSTEM INFORMATION' "$tmpdir/debug-out" ||
  fail "debug log still prints the collected text" "$(cat "$tmpdir/debug-out")"
pass "debug log stays in a private directory and is removed on exit"

cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
for arg in "$@"; do
  [[ $arg == file=@* ]] || continue
  path=${arg#file=@}
  stat -c '%a' "$(dirname "$path")" >"${MODE_DIR:?}"
  stat -c '%a' "$path" >"${MODE_FILE:?}"
  printf '%s\n' "$path" >"${LOG_PATH:?}"
done
printf 'https://logs.example/ok\n'
SH
cat >"$stub_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 1
SH
cat >"$stub_bin/journalctl" <<'SH'
#!/bin/bash
printf 'journal line\n'
SH
chmod +x "$stub_bin/curl" "$stub_bin/omarchy-cmd-present" "$stub_bin/journalctl"

rm -f /tmp/upload-log.txt /tmp/system-info.txt
umask 022
MODE_DIR="$tmpdir/upload-dir-mode" MODE_FILE="$tmpdir/upload-file-mode" LOG_PATH="$tmpdir/upload-path" \
  XDG_RUNTIME_DIR="$runtime" HOME="$tmpdir/home" PATH="$stub_bin:$PATH" \
  bash "$ROOT/bin/omarchy-upload-log" this-boot >"$tmpdir/upload-out" 2>"$tmpdir/upload-err"

[[ ! -e /tmp/upload-log.txt && ! -e /tmp/system-info.txt ]] ||
  fail "upload log is not written to the fixed /tmp paths"
[[ $(cat "$tmpdir/upload-dir-mode") == 700 ]] ||
  fail "upload log directory is private" "$(cat "$tmpdir/upload-dir-mode")"
[[ $(cat "$tmpdir/upload-file-mode") == 600 ]] ||
  fail "upload log file is private" "$(cat "$tmpdir/upload-file-mode")"
[[ ! -e $(cat "$tmpdir/upload-path") ]] || fail "upload log directory is removed on exit"
grep -Fq 'https://logs.example/ok' "$tmpdir/upload-out" ||
  fail "upload log still reports the upload URL" "$(cat "$tmpdir/upload-out")"
pass "upload log stays in a private directory and is removed on exit"
