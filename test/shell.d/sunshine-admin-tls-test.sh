#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

installer="$ROOT/bin/omarchy-install-service-sunshine"
migration="$ROOT/migrations/1793302200.sh"

grep -F 'SUNSHINE_ADMIN_EXEC="omarchy-launch-webapp $SUNSHINE_ADMIN_URL"' "$installer" >/dev/null ||
  fail "Sunshine admin launcher is not a plain webapp command"
if grep -F -- '--ignore-certificate-errors' "$installer" >/dev/null; then
  fail "Sunshine installer still passes --ignore-certificate-errors"
fi
pass "Sunshine admin launcher keeps browser certificate checks enabled"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

home="$tmpdir/home"
apps="$home/.local/share/applications"
mkdir -p "$apps"

old_exec='Exec=omarchy-launch-webapp https://localhost:47990 --ignore-certificate-errors'
new_exec='Exec=omarchy-launch-webapp https://localhost:47990'

cat >"$apps/Sunshine Admin.desktop" <<EOF
[Desktop Entry]
Name=Sunshine Admin
$old_exec
Type=Application
EOF

cat >"$apps/Other.desktop" <<'EOF'
[Desktop Entry]
Name=Other
Exec=omarchy-launch-webapp https://example.com --ignore-certificate-errors
Type=Application
EOF

HOME="$home" XDG_DATA_HOME="$home/.local/share" bash -euo pipefail "$migration"
grep -qxF "$new_exec" "$apps/Sunshine Admin.desktop" ||
  fail "migration drops the certificate bypass from Sunshine Admin" "$(cat "$apps/Sunshine Admin.desktop")"
grep -qxF 'Exec=omarchy-launch-webapp https://example.com --ignore-certificate-errors' "$apps/Other.desktop" ||
  fail "migration leaves a different launcher unchanged"
pass "migration repairs an existing Sunshine Admin launcher"

HOME="$home" XDG_DATA_HOME="$home/.local/share" bash -euo pipefail "$migration"
grep -qxF "$new_exec" "$apps/Sunshine Admin.desktop" ||
  fail "migration is idempotent"
pass "migration leaves a repaired Sunshine Admin launcher unchanged"

empty="$tmpdir/empty-home"
mkdir -p "$empty"
HOME="$empty" bash -euo pipefail "$migration"
pass "migration no-ops when the user has no application launchers"
