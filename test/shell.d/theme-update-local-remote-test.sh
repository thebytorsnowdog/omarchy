#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command git

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$test_tmp/home/.gitconfig"

real_git=$(command -v git)
source_repo="$test_tmp/source"
first_remote="$test_tmp/first.git"
second_remote="$test_tmp/second.git"
theme="$test_tmp/home/.config/omarchy/themes/local"
local_bin="$test_tmp/bin"
mkdir -p "$source_repo" "$local_bin" "$test_tmp/home"

# These fixtures contain text only; all real Git operations permit file
# transport exclusively, including the production updater's actual pull.
local_git() {
  "$real_git" -c protocol.allow=never -c protocol.file.allow=always "$@"
}

local_git -C "$source_repo" init -q --initial-branch=main
local_git -C "$source_repo" config user.name Test
local_git -C "$source_repo" config user.email test@example.com
printf 'base\n' >"$source_repo/colors.toml"
local_git -C "$source_repo" add colors.toml
local_git -C "$source_repo" commit -qm base
base_commit=$(local_git -C "$source_repo" rev-parse HEAD)

local_git -C "$source_repo" checkout -qb tracked
printf 'first\n' >"$source_repo/colors.toml"
local_git -C "$source_repo" commit -qam first
first_commit=$(local_git -C "$source_repo" rev-parse HEAD)
local_git -C "$source_repo" checkout -q main
local_git clone -q --bare "$source_repo" "$first_remote"

local_git -C "$source_repo" checkout -q tracked
printf 'second\n' >"$source_repo/colors.toml"
local_git -C "$source_repo" commit -qam second
second_commit=$(local_git -C "$source_repo" rev-parse HEAD)
local_git -C "$source_repo" checkout -q main
local_git clone -q --bare "$source_repo" "$second_remote"
local_git -C "$second_remote" symbolic-ref HEAD refs/heads/tracked

mkdir -p "$(dirname "$theme")"
local_git clone -q "$first_remote" "$theme"
local_git -C "$theme" branch -q tracked origin/tracked
local_git -C "$theme" config branch.main.remote .
local_git -C "$theme" config branch.main.merge refs/heads/tracked

cat >"$local_bin/git" <<'SH'
#!/bin/bash
exec "$OMARCHY_TEST_REAL_GIT" -c protocol.allow=never -c protocol.file.allow=always "$@"
SH
cat >"$local_bin/omarchy-theme-extras" <<'SH'
#!/bin/bash
printf '%s\n' "$OMARCHY_TEST_THEME"
SH
chmod +x "$local_bin"/*

update_theme() {
  HOME="$test_tmp/home" PATH="$local_bin:$ROOT/bin:$PATH" \
    OMARCHY_TEST_THEME="$theme" OMARCHY_TEST_REAL_GIT="$real_git" \
    bash "$ROOT/bin/omarchy-theme-update" >"$test_tmp/out" 2>&1
}

if ! update_theme; then
  fail "theme update pulls the configured local tracking branch" "$(cat "$test_tmp/out")"
fi
[[ $(local_git -C "$theme" rev-parse HEAD) == "$first_commit" ]] ||
  fail "local dot update merges branch.main.merge rather than HEAD" "$(cat "$test_tmp/out")"
[[ $(<"$theme/colors.toml") == "first" ]] || fail "local dot update applies the tracked theme content"
pass "local dot updates preserve the configured tracking branch with a real pull"

local_git -C "$theme" reset -q --hard "$base_commit"
local_git -C "$theme" config "url.$first_remote.insteadOf" .
local_git -C "$theme" config "url.$second_remote.insteadOf" "$first_remote"
[[ $(local_git -C "$theme" ls-remote --get-url .) == "$first_remote" ]] ||
  fail "Git resolves exactly the first local dot rewrite"

if ! update_theme; then
  fail "theme update permits the local rewritten dot remote" "$(cat "$test_tmp/out")"
fi
[[ $(local_git -C "$theme" rev-parse HEAD) == "$first_commit" ]] ||
  fail "rewritten dot update merges the first remote's tracked branch" "$(cat "$test_tmp/out")"
[[ $(local_git -C "$theme" rev-parse FETCH_HEAD) == "$first_commit" ]] ||
  fail "the actual local fetch comes from the first rewrite"
[[ $(local_git -C "$theme" rev-parse HEAD) != "$second_commit" ]] ||
  fail "dot update does not apply a second URL rewrite"
pass "rewritten dot updates retain tracking refs and use the actual single-step destination"

local_git -C "$theme" reset -q --hard "$base_commit"
local_git -C "$theme" config --unset-all "url.$first_remote.insteadOf"
local_git -C "$theme" config --unset-all "url.$second_remote.insteadOf"
direct_remote="review-alias:theme"
local_git -C "$theme" config branch.main.remote "$direct_remote"
local_git -C "$theme" config "url.$first_remote.insteadOf" "$direct_remote"
if ! update_theme; then
  fail "theme update permits a direct alias to a local repository" "$(cat "$test_tmp/out")"
fi
[[ $(local_git -C "$theme" rev-parse HEAD) == "$first_commit" ]] ||
  fail "direct alias update selects branch.main.merge instead of remote HEAD" "$(cat "$test_tmp/out")"
pass "direct branch aliases preserve their configured tracking refs with a real pull"

local_git -C "$theme" reset -q --hard "$base_commit"
local_git -C "$theme" config "url.$second_remote.insteadOf" "$first_remote"
if ! update_theme; then
  fail "theme update permits the actual single-step local alias destination" "$(cat "$test_tmp/out")"
fi
[[ $(local_git -C "$theme" rev-parse HEAD) == "$first_commit" ]] ||
  fail "direct alias update does not fetch a hypothetical second rewrite" "$(cat "$test_tmp/out")"
[[ $(local_git -C "$theme" rev-parse FETCH_HEAD) == "$first_commit" ]] ||
  fail "direct alias fetch uses the first local destination"
pass "direct branch aliases validate and pull the same single-step destination"
