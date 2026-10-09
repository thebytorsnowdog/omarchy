#!/bin/bash

set -euo pipefail

# Theme update reads the branch's stored fetch destination rather than the
# install argument, so existing clones need the transport policy before pull.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$test_tmp/home/.gitconfig"

theme="$test_tmp/home/.config/omarchy/themes/transport"
mock_bin="$test_tmp/bin"
pull_marker="$test_tmp/pull-reached"
mkdir -p "$theme" "$mock_bin"

real_git=$(command -v git)
"$real_git" -C "$theme" init -q
"$real_git" -C "$theme" remote add origin https://example.com/acme/theme.git

cat >"$mock_bin/git" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [[ $arg == "pull" ]]; then
    printf '%s\n' "$*" >>"$OMARCHY_TEST_PULL_MARKER"
    exit "${OMARCHY_TEST_PULL_STATUS:-70}"
  fi
done
exec "$OMARCHY_TEST_REAL_GIT" "$@"
SH

cat >"$mock_bin/omarchy-theme-extras" <<'SH'
#!/bin/bash
printf '%s\n' "$OMARCHY_TEST_THEME"
SH

chmod +x "$mock_bin"/*

update_theme() {
  HOME="$test_tmp/home" PATH="$mock_bin:$ROOT/bin:$PATH" OMARCHY_TEST_THEME="${1:-$theme}" \
    OMARCHY_TEST_PULL_MARKER="$pull_marker" OMARCHY_TEST_REAL_GIT="$real_git" \
    OMARCHY_TEST_PULL_STATUS="${2:-70}" \
    bash "$ROOT/bin/omarchy-theme-update" >"$test_tmp/out" 2>&1
}

for url in \
  "git://example.com/acme/theme.git" \
  "http://example.com/acme/theme.git" \
  "ftp://example.com/acme/theme.git"; do
  "$real_git" -C "$theme" remote set-url origin "$url"
  rm -f "$pull_marker"

  if update_theme; then
    fail "theme update refuses the stored unauthenticated origin '$url'"
  fi
  [[ ! -e $pull_marker ]] ||
    fail "theme update refuses '$url' before git pull"
  grep -qF "remote set-url origin URL" "$test_tmp/out" ||
    fail "theme update gives an origin migration command for '$url'" "$(cat "$test_tmp/out")"
done

pass "theme update blocks every stored unauthenticated network origin before pull"

for url in \
  "https://example.com/acme/theme.git" \
  "ssh://git@example.com/acme/theme.git" \
  "git+ssh://git@example.com/acme/theme.git" \
  "ssh+git://git@example.com/acme/theme.git" \
  "ftps://example.com/acme/theme.git" \
  "file://$test_tmp/theme.git" \
  "git@example.com:acme/theme.git" \
  "$test_tmp/theme.git"; do
  "$real_git" -C "$theme" remote set-url origin "$url"
  rm -f "$pull_marker"

  update_theme && fail "the pull stub makes the update fail after accepting '$url'"
  [[ -e $pull_marker ]] ||
    fail "theme update lets the authenticated or local origin reach pull: $url" "$(cat "$test_tmp/out")"
done

pass "theme update preserves authenticated network and local origins"

# A bare `git pull` reads the current branch's configured remote, which need not
# be named origin. Check and pass that exact remote so a secure origin cannot
# hide a plaintext upstream, and a securely renamed remote keeps working.
branch=$("$real_git" -C "$theme" symbolic-ref --quiet --short HEAD)
"$real_git" -C "$theme" remote add upstream http://example.com/acme/theme.git
"$real_git" -C "$theme" config "branch.$branch.remote" upstream
"$real_git" -C "$theme" remote set-url origin https://example.com/acme/theme.git
rm -f "$pull_marker"

if update_theme; then
  fail "theme update refuses the branch's plaintext upstream remote"
fi
[[ ! -e $pull_marker ]] ||
  fail "theme update checks the branch remote before pull" "$(cat "$pull_marker")"
grep -qF "'upstream' remote" "$test_tmp/out" ||
  fail "theme update identifies the refused branch remote" "$(cat "$test_tmp/out")"
grep -qF "remote set-url upstream URL" "$test_tmp/out" ||
  fail "theme update gives a migration command for the branch remote" "$(cat "$test_tmp/out")"

"$real_git" -C "$theme" remote set-url upstream https://example.com/acme/theme.git
"$real_git" -C "$theme" remote remove origin
rm -f "$pull_marker"
update_theme && fail "the pull stub fails after accepting the renamed secure remote"
[[ $(<"$pull_marker") == "-C $theme pull -- upstream" ]] ||
  fail "theme update pulls explicitly from the checked branch remote" "$(cat "$pull_marker")"

"$real_git" -C "$theme" config "branch.$branch.remote" http://example.com/acme/theme.git
rm -f "$pull_marker"
if update_theme; then
  fail "theme update refuses a plaintext URL used directly as the branch remote"
fi
[[ ! -e $pull_marker ]] ||
  fail "theme update checks a direct branch URL before pull" "$(cat "$pull_marker")"
grep -qF "config branch.$branch.remote URL" "$test_tmp/out" ||
  fail "theme update gives a migration command for a direct branch URL" "$(cat "$test_tmp/out")"

"$real_git" -C "$theme" config "branch.$branch.remote" secure-theme:acme/theme.git
"$real_git" -C "$theme" config url.git://plain.example/.insteadOf secure-theme:
rm -f "$pull_marker"
if update_theme; then
  fail "theme update refuses a direct branch URL rewritten by checkout-local Git config"
fi
[[ ! -e $pull_marker ]] ||
  fail "theme update uses the theme checkout's URL rewrites before pull" "$(cat "$pull_marker")"
grep -qF "network transport is not authenticated" "$test_tmp/out" ||
  fail "theme update explains a checkout-local rewrite to plaintext" "$(cat "$test_tmp/out")"
"$real_git" -C "$theme" config --unset-all url.git://plain.example/.insteadOf

"$real_git" -C "$theme" config "branch.$branch.remote" https://example.com/acme/theme.git
rm -f "$pull_marker"
update_theme && fail "the pull stub fails after accepting the direct secure branch URL"
[[ $(<"$pull_marker") == "-C $theme pull -- https://example.com/acme/theme.git" ]] ||
  fail "theme update pulls explicitly from the checked direct branch URL" "$(cat "$pull_marker")"

# '.' normally means this local repository, but Git applies checkout-local
# insteadOf rules even to that shorthand. Validate its effective destination.
"$real_git" -C "$theme" config "branch.$branch.remote" .
rm -f "$pull_marker"
update_theme && fail "the pull stub fails after accepting the local dot remote"
[[ $(<"$pull_marker") == "-C $theme pull -- ." ]] ||
  fail "theme update preserves the normal local dot remote" "$(cat "$pull_marker")"
pass "theme update preserves an unrewritten local dot remote"

for url in \
  "git://plain.example/theme.git" \
  "http://plain.example/theme.git" \
  "ftp://plain.example/theme.git"; do
  "$real_git" -C "$theme" config "url.$url.insteadOf" .
  effective=$("$real_git" -C "$theme" ls-remote --get-url .)
  [[ $effective == "$url" ]] ||
    fail "real Git resolves the dot remote without contacting it" "$effective"
  rm -f "$pull_marker"
  if update_theme; then
    fail "theme update refuses a dot remote rewritten to plaintext" "$url"
  fi
  [[ ! -e $pull_marker ]] ||
    fail "theme update checks the effective dot remote before pull" "$(cat "$pull_marker")"
  grep -qF "network transport is not authenticated" "$test_tmp/out" ||
    fail "theme update explains a dot rewrite to plaintext" "$(cat "$test_tmp/out")"
  grep -qF "config branch.$branch.remote URL" "$test_tmp/out" ||
    fail "theme update gives branch migration guidance for a rewritten dot remote" "$(cat "$test_tmp/out")"
  "$real_git" -C "$theme" config --unset-all "url.$url.insteadOf"
done
pass "theme update refuses plaintext destinations behind the local dot remote"

"$real_git" -C "$theme" config url.http://middle.example/theme.git.insteadOf .
"$real_git" -C "$theme" config url.https://secure.example/theme.git.insteadOf http://middle.example/theme.git
rm -f "$pull_marker"
if update_theme; then
  fail "theme update refuses the plaintext first step even if another rewrite would be secure"
fi
[[ ! -e $pull_marker ]] ||
  fail "theme update checks the actual single-step dot destination before pull" "$(cat "$pull_marker")"
"$real_git" -C "$theme" config --unset-all url.http://middle.example/theme.git.insteadOf
"$real_git" -C "$theme" config --unset-all url.https://secure.example/theme.git.insteadOf

"$real_git" -C "$theme" config url.https://middle.example/theme.git.insteadOf .
"$real_git" -C "$theme" config url.http://plain.example/theme.git.insteadOf https://middle.example/theme.git
rm -f "$pull_marker"
update_theme && fail "the pull stub fails after accepting the secure single-step dot destination"
[[ $(<"$pull_marker") == "-C $theme pull -- ." ]] ||
  fail "theme update preserves dot after checking its secure first rewrite" "$(cat "$pull_marker")"
"$real_git" -C "$theme" config --unset-all url.https://middle.example/theme.git.insteadOf
"$real_git" -C "$theme" config --unset-all url.http://plain.example/theme.git.insteadOf
pass "theme update checks the actual single-step dot rewrite rather than a hypothetical chain"

for url in "https://secure.example/theme.git" "$test_tmp/local-theme.git"; do
  "$real_git" -C "$theme" config "url.$url.insteadOf" .
  rm -f "$pull_marker"
  update_theme && fail "the pull stub fails after accepting a secure or local dot rewrite"
  [[ $(<"$pull_marker") == "-C $theme pull -- ." ]] ||
    fail "theme update preserves dot after checking its secure or local destination" "$(cat "$pull_marker")"
  "$real_git" -C "$theme" config --unset-all "url.$url.insteadOf"
done
pass "theme update preserves secure and local destinations behind dot rewrites"

"$real_git" -C "$theme" config --unset "branch.$branch.remote"
"$real_git" -C "$theme" remote add origin https://example.com/acme/theme.git

pass "theme update checks and pulls from the current branch remote or URL"

"$real_git" -C "$theme" remote set-url origin shorthand:acme/theme.git
"$real_git" config --file "$test_tmp/home/.gitconfig" url.git://example.com/.insteadOf shorthand:
rm -f "$pull_marker"

if update_theme; then
  fail "theme update refuses an origin rewritten to an unauthenticated URL"
fi
[[ ! -e $pull_marker ]] ||
  fail "theme update checks the expanded origin before pull"

pass "theme update checks the effective URL after Git origin rewriting"

# A refused checkout must not stop an independent secure checkout, and a later
# successful pull must not erase the earlier refusal from the aggregate status.
refused_theme="$test_tmp/home/.config/omarchy/themes/refused-http"
secure_theme="$test_tmp/home/.config/omarchy/themes/secure-https"
for checkout in "$refused_theme" "$secure_theme"; do
  mkdir -p "$checkout"
  "$real_git" -C "$checkout" init -q
done
"$real_git" -C "$refused_theme" remote add origin http://example.com/refused.git
"$real_git" -C "$secure_theme" remote add origin https://example.com/secure.git

for theme_list in "$refused_theme"$'\n'"$secure_theme" "$secure_theme"$'\n'"$refused_theme"; do
  rm -f "$pull_marker"
  if update_theme "$theme_list" 0; then
    fail "theme update reports a refusal despite another theme's successful pull"
  fi
  [[ -e $pull_marker ]] || fail "theme update continues to the independent secure checkout"
  [[ $(<"$pull_marker") == "-C $secure_theme pull -- origin" ]] ||
    fail "only the secure checkout reaches pull in a mixed batch" "$(cat "$pull_marker")"
  grep -qF "refused-http cannot be updated from its 'origin' remote" "$test_tmp/out" ||
    fail "theme update identifies the refused checkout in a mixed batch" "$(cat "$test_tmp/out")"
  grep -qF "remote set-url origin URL" "$test_tmp/out" ||
    fail "theme update retains migration guidance in a mixed batch" "$(cat "$test_tmp/out")"
done
pass "mixed theme batches continue independent updates and retain failure in both orders"
