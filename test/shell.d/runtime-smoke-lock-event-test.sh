#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/fixtures/runtime-smoke/lock-event.sh"

# Exercise the same assertion the graphical smoke test calls, without a shell
# or compositor. A rejected event must take its actual failure path.
fail_with_log() {
  fail "$1"
}

assert_event() {
  local expected="$1" event="$2" description="$3" actual=0 output

  output=$(assert_runtime_smoke_lock_event "$event" 2>&1) || actual=$?
  (( actual == expected )) || fail "$description" "expected exit $expected, got $actual: $output"
  if (( expected == 1 )); then
    [[ $output == "not ok - plugin rescan does not strand the session lock ($event)" ]] ||
      fail "$description" "unexpected failure: $output"
  else
    [[ -z $output ]] || fail "$description" "unexpected output: $output"
  fi
  pass "$description"
}

assert_event 0 "" "an absent lock event does not fail runtime smoke"
assert_event 0 "init" "an initial lock event does not fail runtime smoke"
assert_event 0 "session-locked=false" "an ordinary lock event does not fail runtime smoke"
assert_event 0 "lock-stranded: left to the session shell" \
  "exact delegation to the session shell does not fail runtime smoke"

assert_event 1 "lock-stranded: recovering" "genuine stranded-lock recovery still fails runtime smoke"
assert_event 1 "lock-stranded" "an unclassified stranded-lock event still fails runtime smoke"
assert_event 1 "lock-stranded: unexpected" "an unknown stranded-lock event still fails runtime smoke"
assert_event 1 "lock-stranded: left to the session shell: recovering" \
  "a delegation prefix cannot hide a stranded-lock event"
assert_event 1 "lock-stranded: left to the session shell " \
  "a near-match delegation event still fails runtime smoke"
