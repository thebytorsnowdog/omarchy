#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

stub_bin="$tmpdir/bin"
mkdir -p "$stub_bin"
log="$tmpdir/calls"
: >"$log"

cat >"$stub_bin/yay" <<'SH'
#!/bin/bash
if [[ ${1:-} == -Slqa ]]; then
  printf 'test-package\n'
  exit 0
fi
printf 'yay' >>"$CALL_LOG"
printf ' %q' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
printf 'sudo-on-path %s\n' "$(command -v sudo)" >>"$CALL_LOG"
SH
cat >"$stub_bin/fzf" <<'SH'
#!/bin/bash
cat >/dev/null
printf 'test-package\n'
SH
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$CALL_LOG"
if [[ ${1:-} == -k ]]; then
  exit 0
fi
exec "$@"
SH
cat >"$stub_bin/updatedb" <<'SH'
#!/bin/bash
printf 'updatedb %s\n' "$*" >>"$CALL_LOG"
SH
cat >"$stub_bin/omarchy-show-done" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub_bin/omarchy-sudo-keepalive" <<'SH'
#!/bin/bash
printf 'keepalive\n' >>"$CALL_LOG"
exit 99
SH
chmod +x "$stub_bin"/*

CALL_LOG="$log" OMARCHY_PATH="$ROOT" PATH="$stub_bin:$PATH" \
  bash "$ROOT/bin/omarchy-pkg-aur-install" >"$tmpdir/out" 2>"$tmpdir/err"

if grep -qxF 'keepalive' "$log"; then
  fail "AUR install does not keep a sudo timestamp across yay" "$(cat "$log")"
fi

wrapper="$ROOT/default/omarchy/sudo-no-update/sudo"
grep -F "yay --sudo $wrapper --sudoloop=false -S --noconfirm aur/test-package" "$log" >/dev/null ||
  fail "AUR install passes yay a non-caching sudo" "$(cat "$log")"
grep -F "sudo-on-path $ROOT/default/omarchy/sudo-no-update/sudo" "$log" >/dev/null ||
  fail "AUR install puts the non-caching sudo on yay's PATH" "$(cat "$log")"

first_k=$(grep -n 'sudo -k' "$log" | head -1 | cut -d: -f1)
yay_line=$(grep -n '^yay ' "$log" | head -1 | cut -d: -f1)
updatedb_line=$(grep -n '^updatedb ' "$log" | head -1 | cut -d: -f1)
[[ -n $first_k && -n $yay_line && -n $updatedb_line ]] ||
  fail "AUR install revokes sudo, runs yay, then updates the locate database" "$(cat "$log")"
(( first_k < yay_line && yay_line < updatedb_line )) ||
  fail "AUR install revokes sudo before yay builds a package" "$(cat "$log")"
grep -F 'updatedb --prune-bind-mounts=no --add-prunepaths=/.snapshots' "$log" >/dev/null ||
  fail "AUR install keeps the locate database options" "$(cat "$log")"
pass "AUR install does not leave a reusable sudo timestamp for PKGBUILDs"
