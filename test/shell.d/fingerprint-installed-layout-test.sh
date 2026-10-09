#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Run unchanged commands at their real installed paths in a scratch root.
# PAM files and service destinations belong to the fixture; every hardware,
# package and service operation is a stub. No host authentication is touched.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fixture="$scratch/root"
package_root="$fixture/usr/share/omarchy"
checkout_root="$fixture/checkout with spaces"
mkdir -p "$fixture"/{usr/bin,usr/lib/systemd/system-sleep,usr/lib64,etc/pam.d,dev,test,links,poison/bin}
ln -s usr/bin "$fixture/bin"
ln -s usr/lib "$fixture/lib"
ln -s usr/lib64 "$fixture/lib64"
printf 'root:x:0:0:Fixture root:/nonexistent:/bin/bash\n' > "$fixture/etc/passwd"
printf 'root:x:0:\n' > "$fixture/etc/group"

for command in bash env readlink grep install tee sed cat rm rmdir dirname; do
  [[ -x /usr/bin/$command ]] || fail "fixture tool is available: $command"
  ln -s "/tools/bin/$command" "$fixture/usr/bin/$command"
done

for tree in "$package_root" "$checkout_root" "$fixture/poison"; do
  mkdir -p "$tree/bin" "$tree/default/systemd/system-sleep" "$tree/default/systemd/system/fprintd.service.d"
  cp "$ROOT/default/systemd/system-sleep/fprintd-resume" "$tree/default/systemd/system-sleep/"
  cp "$ROOT/default/systemd/system/fprintd.service.d/10-stop-timeout.conf" "$tree/default/systemd/system/fprintd.service.d/"
done
# Different benign source bytes distinguish checkout selection from package
# selection; poisoned OMARCHY_PATH must never supply either installed file.
printf '\n# checkout fixture\n' >> "$checkout_root/default/systemd/system-sleep/fprintd-resume"
printf '\n# checkout fixture\n' >> "$checkout_root/default/systemd/system/fprintd.service.d/10-stop-timeout.conf"
printf '\n# poisoned source\n' >> "$fixture/poison/default/systemd/system-sleep/fprintd-resume"
printf '\n# poisoned source\n' >> "$fixture/poison/default/systemd/system/fprintd.service.d/10-stop-timeout.conf"

for command in omarchy-apply-lock omarchy-setup-security-fingerprint; do
  cp "$ROOT/bin/$command" "$fixture/usr/bin/$command"
  cp "$ROOT/bin/$command" "$checkout_root/bin/$command"
  ln -s "/usr/bin/$command" "$package_root/bin/$command"
  ln -s "/checkout with spaces/bin/$command" "$fixture/links/$command"
done

cat > "$fixture/usr/bin/fprintd-list" <<'STUB'
#!/bin/bash
printf 'list %s\n' "$*" >> /test/calls
printf ' - #0: right-index-finger\n'
STUB
cat > "$fixture/usr/bin/fprintd-enroll" <<'STUB'
#!/bin/bash
printf 'enroll %s\n' "$*" >> /test/calls
STUB
cat > "$fixture/usr/bin/fprintd-verify" <<'STUB'
#!/bin/bash
echo verify >> /test/calls
STUB
cat > "$fixture/usr/bin/omarchy-hw-fingerprint" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$fixture/usr/bin/omarchy-pkg-missing" <<'STUB'
#!/bin/bash
exit 1
STUB
cat > "$fixture/usr/bin/pacman" <<'STUB'
#!/bin/bash
echo unexpected-pacman >> /test/calls
exit 99
STUB
cat > "$fixture/usr/bin/sudo" <<'STUB'
#!/bin/bash
case "$1" in
  sed | tee | fprintd-enroll) exec "$@" ;;
  *) echo "Unexpected sudo call: $*" >&2; exit 99 ;;
esac
STUB
cat > "$fixture/usr/bin/systemctl" <<'STUB'
#!/bin/bash
[[ $* == "daemon-reload" ]] || exit 99
echo daemon-reload >> /test/calls
STUB
cat > "$fixture/usr/bin/omarchy-shell" <<'STUB'
#!/bin/bash
exit 1
STUB
cat > "$fixture/poison/bin/omarchy-apply-lock" <<'STUB'
#!/bin/bash
echo poisoned-helper >> /test/calls
exit 99
STUB
for command in "$fixture/usr/bin/"*; do
  [[ -L $command ]] || chmod +x "$command"
done
chmod +x "$checkout_root/bin/"* "$fixture/poison/bin/omarchy-apply-lock"

# bwrap provides an isolated mount/user namespace. PRoot can exercise the same
# layout on builders that disable user namespaces, without needing real root.
# Its library/tool binds are used only by the trusted commands above; all
# production write destinations remain inside the scratch root.
library_binds=(-b /usr/lib:/usr/lib)
bwrap_libraries=(--ro-bind /usr/lib /usr/lib)
if [[ -d /usr/lib64 ]]; then
  library_binds+=(-b /usr/lib64:/usr/lib64)
  bwrap_libraries+=(--ro-bind /usr/lib64 /usr/lib64)
fi
sandbox=()
if command -v bwrap >/dev/null; then
  sandbox=(bwrap --die-with-parent --unshare-all --uid 0 --gid 0
    --bind "$fixture" / --ro-bind /usr/bin /tools/bin
    "${bwrap_libraries[@]}" --bind "$fixture/usr/lib/systemd" /usr/lib/systemd
    --dev /dev --chdir /)
  if ! "${sandbox[@]}" /usr/bin/env -i /bin/bash -c '(( EUID == 0 ))' >/dev/null 2>&1; then
    sandbox=()
  fi
fi
if (( ${#sandbox[@]} == 0 )) && command -v proot >/dev/null; then
  sandbox=(proot -0 -r "$fixture" -w / -b /usr/bin:/tools/bin
    "${library_binds[@]}" -b "$fixture/usr/lib/systemd:/usr/lib/systemd" -b /dev/null:/dev/null)
  if ! "${sandbox[@]}" /usr/bin/env -i /bin/bash -c '(( EUID == 0 ))' >/dev/null 2>&1; then
    sandbox=()
  fi
fi
if (( ${#sandbox[@]} == 0 )); then
  skip "no usable bwrap or PRoot; skipping fingerprint installed-layout behavior"
  exit 0
fi

reset_fixture() {
  rm -f "$fixture/etc/pam.d/omarchy-lock-"* "$fixture/usr/lib/systemd/system-sleep/fprintd-resume"
  rm -rf "$fixture/etc/systemd"
  printf 'auth include system-auth\n' > "$fixture/etc/pam.d/sudo"
  printf 'auth include system-auth\n' > "$fixture/etc/pam.d/polkit-1"
  : > "$fixture/test/calls"
}

check_layout() {
  local description="$1" entry="$2" expected_tree="$3" setup="$4"
  reset_fixture
  if ! "${sandbox[@]}" /usr/bin/env -i PATH=/usr/share/omarchy/bin:/usr/bin:/bin \
    USER=fixture-user OMARCHY_INSTALL_USER=fixture-user OMARCHY_PATH=/poison \
    OMARCHY_FPRINTD_RESUME_HOOK_SRC=/poison/default/systemd/system-sleep/fprintd-resume \
    OMARCHY_FPRINTD_RESUME_HOOK_DST=/poison/resume-installed \
    OMARCHY_FPRINTD_STOP_TIMEOUT_SRC=/poison/default/systemd/system/fprintd.service.d/10-stop-timeout.conf \
    OMARCHY_FPRINTD_STOP_TIMEOUT_DST=/poison/timeout-installed \
    "$entry" > "$scratch/output" 2>&1; then
    fail "$description completes" "$(<"$scratch/output")"
  fi
  cmp "$expected_tree/default/systemd/system-sleep/fprintd-resume" "$fixture/usr/lib/systemd/system-sleep/fprintd-resume" ||
    fail "$description installs its own resume hook"
  cmp "$expected_tree/default/systemd/system/fprintd.service.d/10-stop-timeout.conf" "$fixture/etc/systemd/system/fprintd.service.d/10-stop-timeout.conf" ||
    fail "$description installs its own timeout drop-in"
  [[ $(stat -c %a "$fixture/usr/lib/systemd/system-sleep/fprintd-resume") == "755" ]] || fail "$description installs executable hook permissions"
  [[ $(stat -c %a "$fixture/etc/systemd/system/fprintd.service.d/10-stop-timeout.conf") == "644" ]] || fail "$description installs drop-in permissions"
  grep -q pam_unix.so "$fixture/etc/pam.d/omarchy-lock-password" || fail "$description retains password PAM"
  grep -q pam_fprintd.so "$fixture/etc/pam.d/omarchy-lock-fingerprint" || fail "$description configures fingerprint PAM"
  grep -qx 'list fixture-user' "$fixture/test/calls" || fail "$description probes the intended user"
  grep -qx daemon-reload "$fixture/test/calls" || fail "$description reloads the fixture service manager"
  [[ ! -e $fixture/poison/resume-installed && ! -e $fixture/poison/timeout-installed ]] || fail "$description ignores inherited destinations"
  if grep -qE 'poisoned-helper|unexpected-pacman' "$fixture/test/calls"; then
    fail "$description uses only its intended helper and installed packages"
  fi
  if [[ $setup == "yes" ]]; then
    grep -qx 'enroll fixture-user' "$fixture/test/calls" || fail "$description enrolls before configuring PAM"
    grep -qx verify "$fixture/test/calls" || fail "$description verifies enrollment"
    for stack in sudo polkit-1; do
      grep -q pam_fprintd.so "$fixture/etc/pam.d/$stack" || fail "$description configures $stack"
      grep -q 'pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed' "$fixture/etc/pam.d/$stack" || fail "$description keeps the fixed $stack clamshell gate"
    done
    grep -q 'Perfect! Fingerprint authentication is now configured.' "$scratch/output" || fail "$description confirms successful lock configuration"
  fi
  pass "$description ignores poisoned sources and destinations and installs the expected files"
}

for command in omarchy-apply-lock omarchy-setup-security-fingerprint; do
  setup=no
  [[ $command != "omarchy-setup-security-fingerprint" ]] || setup=yes
  check_layout "$command packaged binary" "/usr/bin/$command" "$package_root" "$setup"
  check_layout "$command packaged symlink" "/usr/share/omarchy/bin/$command" "$package_root" "$setup"
  check_layout "$command checkout with spaces" "/checkout with spaces/bin/$command" "$checkout_root" "$setup"
  check_layout "$command checkout symlink" "/links/$command" "$checkout_root" "$setup"
done
