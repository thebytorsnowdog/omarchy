#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

test_home="$test_tmp/home"
mock_bin="$test_tmp/bin"
flags_dir="$test_home/.config/omarchy/agents"
launch_log="$test_tmp/launch"
inline_log="$test_tmp/inline"
mkdir -p "$mock_bin" "$flags_dir"

cat >"$mock_bin/omarchy-default-agent" <<'SH'
#!/bin/bash
printf '%s\n' "$OMARCHY_TEST_AGENT"
SH

cat >"$mock_bin/omarchy-cmd-missing" <<'SH'
#!/bin/bash
exit 1
SH

cat >"$mock_bin/omarchy-launch-tui" <<'SH'
#!/bin/bash
printf '%s\0' "$@" >>"$OMARCHY_TEST_AGENT_LAUNCH_LOG"
SH

cat >"$mock_bin/opencode" <<'SH'
#!/bin/bash
printf '%s\0' "${0##*/}" "$@" >>"$OMARCHY_TEST_AGENT_INLINE_LOG"
SH
ln -s opencode "$mock_bin/crush"
ln -s opencode "$mock_bin/omarchy-launch-openclaw"
chmod +x "$mock_bin"/*

run_agent() {
  local agent=$1
  shift
  HOME="$test_home" PATH="$mock_bin:$PATH" OMARCHY_PATH="$ROOT" \
    OMARCHY_TEST_AGENT="$agent" OMARCHY_TEST_AGENT_LAUNCH_LOG="$launch_log" \
    OMARCHY_TEST_AGENT_INLINE_LOG="$inline_log" \
    "$ROOT/bin/omarchy-agent" "$@"
}

assert_arguments() {
  local log=$1
  shift
  local expected=("$@") actual index
  mapfile -d '' -t actual <"$log"
  (( ${#actual[@]} == ${#expected[@]} )) || fail "agent launch preserves argument count" "${actual[*]}"
  for ((index = 0; index < ${#expected[@]}; index++)); do
    [[ ${actual[index]} == "${expected[index]}" ]] || fail "agent launch preserves each argument" "${actual[*]}"
  done
}

run_agent opencode
assert_arguments "$launch_log" --app-id=org.omarchy.agent opencode --auto
pass "missing agent flags file keeps the default flags"

: >"$launch_log"
printf '%s\n' ' # A comment' '' '  --model  ' >"$flags_dir/opencode.flags"
printf '%s' '  model with spaces  ' >>"$flags_dir/opencode.flags"
run_agent opencode
assert_arguments "$launch_log" --app-id=org.omarchy.agent opencode --model "model with spaces"
pass "agent flags reader preserves trimmed arguments and a final line without a newline"

: >"$flags_dir/opencode.flags"
run_agent opencode --inline --prompt "Review this project"
assert_arguments "$inline_log" opencode --prompt "Review this project"
pass "empty agent flags file removes defaults and keeps prompt arguments"

if (( EUID == 0 )); then
  skip "unreadable agent flags require a non-root user"
else
  printf '%s\n' '--model' 'chosen-model' >"$flags_dir/opencode.flags"
  chmod 000 "$flags_dir/opencode.flags"
  [[ ! -r $flags_dir/opencode.flags ]] || fail "agent flags fixture is unreadable"

  for mode in terminal inline; do
    for prompted in false true; do
      args=()
      [[ $mode == "inline" ]] && args+=(--inline)
      [[ $prompted == "true" ]] && args+=(--prompt "Review this project")
      : >"$launch_log"
      : >"$inline_log"
      if run_agent opencode "${args[@]}" >"$test_tmp/output" 2>&1; then
        fail "unreadable flags stop $mode launch (prompted=$prompted)"
      fi
      grep -Fx "Could not read agent flags file: $flags_dir/opencode.flags" "$test_tmp/output" >/dev/null ||
        fail "unreadable flags identify the file that stopped the launch" "$(cat "$test_tmp/output")"
      [[ ! -s $launch_log && ! -s $inline_log ]] || fail "unreadable flags start neither terminal nor agent"
    done
  done
  chmod 600 "$flags_dir/opencode.flags"
  pass "unreadable agent flags stop terminal and inline launches with or without a prompt"

  # These launch paths have no replaceable unattended flags and must not try
  # reading a flags file even when one exists but cannot be read.
  for agent in crush openclaw; do
    printf '%s\n' '--model' 'ignored-model' >"$flags_dir/$agent.flags"
    chmod 000 "$flags_dir/$agent.flags"
  done
  : >"$inline_log"
  run_agent crush --inline --prompt "Review this project"
  assert_arguments "$inline_log" crush run "Review this project"
  for prompted in false true; do
    args=(--inline)
    expected=(omarchy-launch-openclaw --tui)
    if [[ $prompted == "true" ]]; then
      args+=(--prompt "Review this project")
      expected+=(--message "Review this project")
    fi
    : >"$inline_log"
    run_agent openclaw "${args[@]}"
    assert_arguments "$inline_log" "${expected[@]}"
  done
  pass "prompted Crush and OpenClaw ignore unreadable flags files"
fi
