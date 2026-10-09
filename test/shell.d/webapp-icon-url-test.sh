#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command /usr/bin/python3
require_command file

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin" "$test_tmp/home"

# Use a real image so the production MIME check also has to succeed.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' \
  | base64 -d >"$test_tmp/icon.png"

cat >"$test_tmp/bin/curl" <<'CURL'
#!/bin/bash
set -euo pipefail

output=""
url=""
while (($#)); do
  case "$1" in
  -o)
    output=$2
    shift 2
    ;;
  --max-time | --max-redirs)
    shift 2
    ;;
  -fsSL)
    shift
    ;;
  *)
    url=$1
    shift
    ;;
  esac
done
printf '%s\n' "$url" >>"$CURL_URLS"
if [[ -n $output ]]; then
  if [[ $CURL_MODE == "fallback" && $url != "https://www.google.com/s2/favicons?"* ]]; then
    exit 1
  fi
  cp "$ICON_FIXTURE" "$output"
fi
CURL
printf '#!/bin/bash\nexit 0\n' >"$test_tmp/bin/gtk-update-icon-cache"
# A user's mise interpreter must not replace the system standard-library parser.
printf '#!/bin/bash\nexit 99\n' >"$test_tmp/bin/python3"
chmod +x "$test_tmp/bin"/*

run_install() {
  : >"$test_tmp/requests"
  rm -f "$test_tmp/home/.local/share/applications/Example.desktop"
  HOME="$test_tmp/home" OMARCHY_PATH="$ROOT" PATH="$test_tmp/bin:$PATH" \
    CURL_URLS="$test_tmp/requests" CURL_MODE="${3:-icon}" ICON_FIXTURE="$test_tmp/icon.png" \
    bash "$ROOT/bin/omarchy-webapp-install" Example "$1" "$2" "" "" \
    >"$test_tmp/out" 2>"$test_tmp/err"
}

expect_fetch() {
  local url=$1
  if ! run_install "$url" ""; then
    fail "webapp icon fetch accepts $url" "$(cat "$test_tmp/err")"
  fi
  grep -Fxq -- "$url" "$test_tmp/requests" ||
    fail "webapp icon fetch requests the original URL" "$(cat "$test_tmp/requests")"
  [[ -s $test_tmp/home/.local/share/icons/hicolor/256x256/apps/example.png ]] ||
    fail "webapp icon fetch installs the downloaded image"
  [[ -f $test_tmp/home/.local/share/applications/Example.desktop ]] ||
    fail "webapp icon fetch completes the launcher"
}

# This valid DNS label previously became the arithmetic expression 20-example,
# yielding 20 when the variable example was unset and rejecting the hostname.
expect_fetch "https://172.20-example.test/"
expect_fetch "https://10.docs.example.test/"
pass "numeric hostname labels stay data during icon fetching"

for url in "https://172.15.255.255/" "https://172.32.0.0/" "https://8.8.8.8/"; do
  expect_fetch "$url"
done
pass "icon fetching accepts canonical public IPv4 boundaries"

for url in \
  "http://10.0.0.1/" \
  "http://127.0.0.1/" \
  "http://192.168.0.1/" \
  "http://169.254.169.254/" \
  "http://172.16.0.0/" \
  "http://172.31.255.255/" \
  "HTTP://LOCALHOST.:8080/" \
  "HTTP://reader:sample@127.0.0.1:8080/" \
  "https://[::1]:8080/" \
  "https://[0:0:0:0:0:0:0:1]/" \
  "https://[fe90::1]/" \
  "https://[fd00::1]/" \
  "https://[::ffff:127.0.0.1]/"; do
  if run_install "$url" ""; then
    fail "webapp icon fetch refuses private literals" "$url"
  fi
  grep -Fq 'Private/internal URLs not allowed' "$test_tmp/err" ||
    fail "webapp icon fetch explains the private-address refusal" "$(cat "$test_tmp/err")"
  [[ ! -s $test_tmp/requests ]] ||
    fail "webapp icon fetch refuses private addresses before curl" "$(cat "$test_tmp/requests")"
  [[ ! -e $test_tmp/home/.local/share/applications/Example.desktop ]] ||
    fail "webapp icon fetch writes no launcher for a refused address"
done
pass "icon fetching parses private literals through case, credentials, ports and IPv6"

for url in \
  "https:///missing-authority" \
  "https://example.test:70000/" \
  "https://example.test:bad/" \
  "https://172.256.0.1/" \
  "https://172.016.0.1/" \
  "https://172.160000000000000000000000000.0.1/" \
  "https://2130706433/" \
  "https://0x7f000001/"; do
  if run_install "$url" ""; then
    fail "webapp icon fetch refuses invalid authority and noncanonical IP literals" "$url"
  fi
  grep -Fq 'Invalid HTTP/HTTPS icon URL' "$test_tmp/err" ||
    fail "webapp icon fetch explains an invalid URL" "$(cat "$test_tmp/err")"
  [[ ! -s $test_tmp/requests ]] ||
    fail "webapp icon fetch refuses malformed literals before curl" "$(cat "$test_tmp/requests")"
done
pass "icon fetching bounds decimal literals before numeric conversion"

expect_fetch "HTTPS://[2606:4700:4700::1111]:8443/"
pass "icon fetching accepts bracketed public IPv6 with a port"

if run_install "https://app.example.test/" "HTTPS://reader:sample@127.0.0.1:8443/icon.png"; then
  fail "explicit icon URL refuses private hosts"
fi
[[ ! -s $test_tmp/requests ]] ||
  fail "explicit icon URL refuses private hosts before curl"
if ! run_install "https://app.example.test/" "HTTPS://icons.example.test:8443/icon.png"; then
  fail "explicit icon URL accepts uppercase HTTP schemes" "$(cat "$test_tmp/err")"
fi
[[ $(cat "$test_tmp/requests") == "HTTPS://icons.example.test:8443/icon.png" ]] ||
  fail "explicit icon URL is downloaded instead of treated as an icon name"
pass "explicit icon downloads use the same hostname validation"

if ! run_install "HTTPS://reader:sample@Example.test:8443?token=sample#view" "" fallback; then
  fail "webapp icon fetch reaches the Google fallback" "$(cat "$test_tmp/err")"
fi
mapfile -t requests <"$test_tmp/requests"
[[ ${#requests[@]} == 3 ]] || fail "fallback makes only the expected requests" "$(cat "$test_tmp/requests")"
[[ ${requests[1]} == "https://reader:sample@Example.test:8443/apple-touch-icon.png" ]] ||
  fail "first-party icon URL keeps authority and removes query and fragment" "${requests[1]}"
[[ ${requests[2]} == "https://www.google.com/s2/favicons?domain=example.test&sz=256" ]] ||
  fail "Google receives only the hostname" "${requests[2]}"
pass "Google fallback excludes credentials, ports, query and fragment"

if ! run_install "https://[2606:4700:4700::1111]:8443/?token=sample" "" fallback; then
  fail "webapp icon fetch reaches the IPv6 Google fallback" "$(cat "$test_tmp/err")"
fi
[[ $(tail -1 "$test_tmp/requests") == "https://www.google.com/s2/favicons?domain=2606%3A4700%3A4700%3A%3A1111&sz=256" ]] ||
  fail "Google hostname is query-encoded" "$(cat "$test_tmp/requests")"
pass "Google fallback encodes a parsed IPv6 hostname"
