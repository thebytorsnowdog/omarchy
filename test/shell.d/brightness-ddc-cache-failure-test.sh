#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mock_bin="$test_tmp/bin"
state_home="$test_tmp/state"
cache_dir="$state_home/omarchy/omarchy-brightness-display-ddc"
cache_file="$cache_dir/DP-1.bus"
call_log="$test_tmp/calls"
mkdir -p "$mock_bin" "$cache_dir"

for command in mkdir chmod; do
  cat >"$mock_bin/$command" <<'SH'
#!/bin/bash
if [[ ${DDC_CACHE_FAILURE:-} == "${0##*/}" && ${@: -1} == "$DDC_CACHE_DIR" ]]; then
  exit 1
fi
exec "/usr/bin/${0##*/}" "$@"
SH
done
cat >"$mock_bin/ddcutil" <<'SH'
#!/bin/bash
printf 'ddcutil %s\n' "$*" >>"$CALL_LOG"
if [[ $* == *" detect --brief"* ]]; then
  [[ ${DDC_FAILURE:-} != "detect" ]] || exit 1
  printf '   I2C bus:             /dev/i2c-7\n'
  printf '   DRM connector:       card1-DP-1\n'
elif [[ $* == *" getvcp 10 "* ]]; then
  [[ ${DDC_FAILURE:-} != "read" ]] || exit 1
  printf 'VCP 10 C 40 80\n'
else
  [[ ${DDC_FAILURE:-} != "write" ]] || exit 1
fi
SH
chmod +x "$mock_bin/"*

run_ddc() {
  HOME="$test_tmp/home" XDG_STATE_HOME="$state_home" XDG_RUNTIME_DIR= \
    DDC_CACHE_DIR="$cache_dir" CALL_LOG="$call_log" PATH="$mock_bin:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-brightness-display-ddc" DP-1 "$@" 2>"$test_tmp/error"
}

assert_cache_untouched() {
  cmp -s "$cache_file" "$test_tmp/before.bus" || fail "an unsecured bus cache is not rewritten or removed"
  cmp -s "$cache_dir/boot-id" "$test_tmp/before.boot" || fail "an unsecured boot marker is not rewritten or removed"
}

# These failures model an existing fallback outside a private home whose
# permissions cannot be secured. The command must ignore it, not assume that
# a readable cache is private. Every DDC call below is a recording stub.
for failure in mkdir chmod; do
  chmod 777 "$cache_dir"
  printf '99 80 %s\n' "$(date +%s)" >"$cache_file"
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    cat /proc/sys/kernel/random/boot_id >"$cache_dir/boot-id"
  else
    printf 'existing-boot\n' >"$cache_dir/boot-id"
  fi
  cp "$cache_file" "$test_tmp/before.bus"
  cp "$cache_dir/boot-id" "$test_tmp/before.boot"

  for mode in query absolute increase decrease; do
    : >"$call_log"
    case $mode in
    query) step=(); expected=50 ;;
    absolute) step=(25%); expected=25 ;;
    increase) step=(+5%); expected=55 ;;
    decrease) step=(5%-); expected=45 ;;
    esac
    actual=$(DDC_CACHE_FAILURE="$failure" run_ddc "${step[@]}")
    [[ $actual == "$expected" ]] || fail "uncached $mode brightness remains available after $failure failure" "$actual"
    grep -Fq 'ddcutil --skip-ddc-checks detect --brief' "$call_log" || fail "an unsecured cache is ignored after $failure failure"
    grep -Fq 'ddcutil --bus 7 --skip-ddc-checks getvcp 10 --brief' "$call_log" || fail "uncached $mode reads the detected display"
    ! grep -Fq -- '--bus 99' "$call_log" || fail "the unprotected cached bus is not used"
    grep -Fq 'continuing without cache' "$test_tmp/error" || fail "cache privacy failure is reported"
    assert_cache_untouched
    pass "$failure failure leaves $mode brightness available without reading or changing unsecured cache state"
  done

  # Failed detection, reads and writes must also avoid negative cache writes
  # and cleanup operations against the unprotected cache.
  for ddc_failure in detect read write; do
    : >"$call_log"
    if DDC_CACHE_FAILURE="$failure" DDC_FAILURE="$ddc_failure" run_ddc 25% >/dev/null; then
      fail "uncached $ddc_failure errors still fail the brightness operation"
    fi
    assert_cache_untouched
  done
  pass "$failure failure leaves unsecured cache state untouched on DDC errors"
done

# Once privacy can be established again, ordinary cache behavior resumes.
rm "$cache_file"
: >"$call_log"
[[ $(run_ddc) == "50" ]] || fail "secured fallback brightness works"
[[ $(stat -c %a "$cache_dir") == "700" ]] || fail "the recovered fallback is private"
[[ $(cut -d' ' -f1,2 "$cache_file") == "7 80" ]] || fail "the recovered fallback stores the detected bus and range"
pass "a fallback that can be secured resumes normal cache storage"
: >"$call_log"
[[ $(run_ddc 25%) == "25" ]] || fail "secured cached brightness works"
[[ $(cat "$call_log") == "ddcutil --bus 7 --skip-ddc-checks --noverify setvcp 10 20" ]] || fail "the secured fallback reuses its cached range"
pass "a secured fallback retains efficient absolute brightness updates"
