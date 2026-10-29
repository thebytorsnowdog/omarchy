#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command unshare

migration="$ROOT/migrations/1793302300.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

stub_bin="$tmpdir/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash
exit 1
SH
cat >"$stub_bin/omarchy-update-keyring" <<'SH'
#!/bin/bash
echo "keyring should not run" >>"${CALL_LOG:?}"
exit 1
SH
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
if [[ $1 == pacman-key ]]; then
  exit 0
fi
if [[ $1 == sed ]]; then
  shift
  exec /usr/bin/sed "$@"
fi
echo "unexpected sudo $*" >>"${CALL_LOG:?}"
exit 1
SH
chmod +x "$stub_bin"/*

write_conf() {
  local dest="$1"
  cat >"$dest" <<'EOF'
[options]
SigLevel = Required DatabaseOptional

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch

[core]
Include = /etc/pacman.d/mirrorlist
EOF
}

run_migration() {
  local conf="$1"
  : >"$tmpdir/calls"
  # The migration edits the real /etc/pacman.conf path. A user namespace with
  # a private /etc lets that path be a scratch file.
  unshare --user --map-root-user --mount bash -euo pipefail -c '
    mount -t tmpfs tmpfs /etc
    cp "$1" /etc/pacman.conf
    PATH="$2:$PATH" CALL_LOG="$3" bash -euo pipefail "$4"
    cp /etc/pacman.conf "$1"
  ' bash "$conf" "$stub_bin" "$tmpdir/calls" "$migration"
}

conf="$tmpdir/pacman.conf"
write_conf "$conf"
run_migration "$conf"
if grep -qxF 'SigLevel = Optional TrustAll' "$conf"; then
  fail "migration removes Optional TrustAll from the Omarchy repository" "$(cat "$conf")"
fi
grep -qxF 'SigLevel = Required DatabaseOptional' "$conf" ||
  fail "migration leaves the global signature policy alone"
grep -qxF 'Server = https://pkgs.omarchy.org/stable/$arch' "$conf" ||
  fail "migration leaves the Omarchy server line alone"
[[ ! -s $tmpdir/calls ]] || fail "migration does not reinstall the keyring when it is already present"
pass "migration removes a repeated TrustAll override once the packaging key is present"

run_migration "$conf"
if grep -qxF 'SigLevel = Optional TrustAll' "$conf"; then
  fail "migration stays idempotent" "$(cat "$conf")"
fi
pass "migration no-ops when the Omarchy repository already requires signatures"

write_conf "$conf"
cat >>"$conf" <<'EOF'

[custom]
SigLevel = Optional TrustAll
Server = https://example.invalid
EOF
run_migration "$conf"
grep -qxF 'SigLevel = Optional TrustAll' "$conf" ||
  fail "migration leaves TrustAll on a repository other than omarchy" "$(cat "$conf")"
if sed -n '/^\[omarchy\]/,/^\[/p' "$conf" | grep -qxF 'SigLevel = Optional TrustAll'; then
  fail "migration still removes TrustAll from the Omarchy section" "$(cat "$conf")"
fi
pass "migration only edits the Omarchy repository section"
