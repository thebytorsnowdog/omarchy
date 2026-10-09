#!/bin/bash

assert_runtime_smoke_lock_event() {
  local event="$1"

  # The different-tree smoke shell leaves a healthy lock to the session shell.
  # Only that exact delegation event is harmless; recovery still fails smoke.
  [[ $event != lock-stranded* || $event == "lock-stranded: left to the session shell" ]] ||
    fail_with_log "plugin rescan does not strand the session lock ($event)"
}
