#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mock_bin="$scratch/bin"
calls="$scratch/calls"
clients="$scratch/clients.json"
mkdir -p "$mock_bin" "$calls" "$scratch/work"
touch "$scratch/work/wildcard-one" "$scratch/work/wildcard-two"

# The real wrapper, dispatcher (including eval), and webapp launcher run.
# Only compositor, session, desktop lookup and browser operations are stubs.
# setsid executes synchronously so every NUL-delimited argv log is complete
# before assertions run, without creating a browser, window or session.
cat > "$mock_bin/hyprctl" <<'STUB'
#!/bin/bash
case "$1" in
  clients)
    printf '%s\0' "$@" > "$OMARCHY_TEST_CALLS/query"
    cat "$OMARCHY_TEST_CLIENTS"
    ;;
  dispatch)
    printf '%s\0' "$@" >> "$OMARCHY_TEST_CALLS/focus"
    if [[ $2 == "hl.dsp.focus("* ]]; then
      exit "$OMARCHY_TEST_LUA_FOCUS"
    fi
    [[ $2 == "focuswindow" ]]
    ;;
  *) exit 99 ;;
esac
STUB
cat > "$mock_bin/setsid" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" >> "$OMARCHY_TEST_CALLS/setsid"
exec "$@"
STUB
cat > "$mock_bin/omarchy-cmd-default-browser" <<'STUB'
#!/bin/bash
echo chromium.desktop
STUB
cat > "$mock_bin/sed" <<'STUB'
#!/bin/bash
# Stand in for the browser desktop's Exec line; never read host desktop files.
[[ $1 == "-n" && $2 == 's/^Exec=\([^ ]*\).*/\1/p' ]] || exit 99
echo fixture-browser
STUB
cat > "$mock_bin/omarchy-cmd-browser-handoff" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" > "$OMARCHY_TEST_CALLS/handoff"
if [[ $OMARCHY_TEST_HANDOFF == "0" ]]; then
  exec "$@"
else
  exit 1
fi
STUB
cat > "$mock_bin/uwsm-app" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" > "$OMARCHY_TEST_CALLS/uwsm"
[[ $1 == "--" ]] || exit 99
shift
exec "$@"
STUB
cat > "$mock_bin/fixture-browser" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" > "$OMARCHY_TEST_CALLS/browser"
STUB
chmod +x "$mock_bin/"*

assert_argv() {
  local description="$1" file="$2"
  shift 2
  [[ -f $file ]] || fail "$description" "missing argv log: ${file##*/}"
  printf '%s\0' "$@" > "$scratch/expected"
  cmp -s "$scratch/expected" "$file" || fail "$description" "$(od -An -tc "$file")"
}

reset_calls() {
  rm -f "$calls/"*
}

run_wrapper() {
  local handoff="$1" lua_focus="$2"
  shift 2
  (cd "$scratch/work" && env -i PATH="$mock_bin:$ROOT/bin:/usr/bin:/bin" LC_ALL=C \
    OMARCHY_TEST_CALLS="$calls" OMARCHY_TEST_CLIENTS="$clients" \
    OMARCHY_TEST_HANDOFF="$handoff" OMARCHY_TEST_LUA_FOCUS="$lua_focus" \
    "$ROOT/bin/omarchy-launch-or-focus-webapp" "$@") > "$scratch/output" 2>&1 ||
    fail "the real webapp wrapper and dispatcher complete" "$(<"$scratch/output")"
}

check_launch() {
  local description="$1" handoff="$2" url="$3"
  shift 3
  reset_calls
  printf '[]\n' > "$clients"
  run_wrapper "$handoff" 0 fixtureapp "$url" "$@"
  assert_argv "$description queries the compositor" "$calls/query" clients -j
  assert_argv "$description reaches browser handoff unchanged" "$calls/handoff" fixture-browser "--app=$url" "$@"
  assert_argv "$description preserves final browser argv" "$calls/browser" "--app=$url" "$@"
  [[ ! -e $calls/focus ]] || fail "$description launches without a focus dispatch"
  if [[ $handoff == "0" ]]; then
    assert_argv "$description preserves argv through the real eval dispatcher" "$calls/setsid" omarchy-launch-webapp "$url" "$@"
    [[ ! -e $calls/uwsm ]] || fail "$description suppresses fallback after handoff"
  else
    assert_argv "$description preserves both session-launch argument vectors" "$calls/setsid" \
      omarchy-launch-webapp "$url" "$@" uwsm-app -- fixture-browser "--app=$url" "$@"
    assert_argv "$description falls back to the browser launcher" "$calls/uwsm" -- fixture-browser "--app=$url" "$@"
  fi
  pass "$description"
}

# Keep whitespace first: the pre-fix control fails here before any case with
# shell metacharacters can run. Substitution markers below contain no command;
# they are literal argv data, never executable payloads or external operations.
check_launch "spaces and empty arguments survive wrapper serialization" 0 \
  'https://example.invalid/path with spaces' '--profile-directory=Review Profile' ''
check_launch "URL query separators remain one argument" 0 \
  'https://example.invalid/?one=1&two=2;three=3' '--enable-features=One,Two'
check_launch "quotes and backslashes remain literal" 0 \
  "https://example.invalid/?double=\"value\"&single='value'&slash=\\path" "--name=Reviewer's App"
check_launch "substitution syntax remains literal data" 0 \
  'https://example.invalid/$( )/``/$((7 + 11))/${OMARCHY_LITERAL}' \
  '$( )' '``' '$((1 + 2))' '${OMARCHY_LITERAL}'
check_launch "globs and leading-dash flags retain their argument boundaries" 0 \
  'https://example.invalid/*?q=[ab]' 'wildcard-*' '--class=Review App' '--' '-literal-flag'
check_launch "newlines and non-ASCII URL bytes survive serialization" 0 \
  $'https://example.invalid/caf\xc3\xa9\nsecond-line' $'--name=tab\tvalue'
check_launch "failed browser handoff preserves argv in the launch fallback" 1 \
  'https://example.invalid/path with spaces?one=1&two=2' '--profile-directory=Review Profile' ''

check_focus() {
  local description="$1" lua_focus="$2" expected_address="$3"
  reset_calls
  run_wrapper 0 "$lua_focus" fixtureapp 'https://example.invalid/?one=1&two=2' 'wildcard-*'
  assert_argv "$description queries the compositor" "$calls/query" clients -j
  local lua_dispatch="hl.dsp.focus({ window = \"address:$expected_address\" })"
  if [[ $lua_focus == "0" ]]; then
    assert_argv "$description focuses the selected match" "$calls/focus" dispatch "$lua_dispatch"
  else
    assert_argv "$description falls back after Lua focus failure" "$calls/focus" dispatch "$lua_dispatch" dispatch focuswindow "address:$expected_address"
  fi
  for operation in setsid handoff uwsm browser; do
    [[ ! -e $calls/$operation ]] || fail "$description suppresses $operation"
  done
  pass "$description"
}

cat > "$clients" <<'JSON'
[
  {"class":"unrelated","title":"other","address":"0x111"},
  {"class":"FixtureApp","title":"first match","address":"0x222"},
  {"class":"other","title":"fixtureapp tab","address":"0x333"}
]
JSON
check_focus "first case-insensitive class match is focused without launching" 0 0x222
check_focus "failed Lua focus uses native focus without launching" 1 0x222
printf '%s\n' '[{"class":"other","title":"a FixtureApp tab","address":"0x444"}]' > "$clients"
check_focus "a matching title is focused without launching" 0 0x444
