#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command /usr/bin/python3
require_command file

test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT

/usr/bin/python3 - "$ROOT" "$test_tmp" <<'PY'
import base64
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import time

root, work = map(Path, sys.argv[1:])
stub_bin = work / "bin"
stub_bin.mkdir()
image = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
(work / "image.png").write_bytes(image)

# Respond once per curl invocation. Old -L callers are modelled honestly by
# following fixture Locations within the stub; no URL reaches the network.
(stub_bin / "curl").write_text(r'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import shutil
import sys
import time
from urllib.parse import urljoin

args = sys.argv[1:]
output = None
write_out = False
limit = None
budget = None
follow = False
url = ""
i = 0
while i < len(args):
  arg = args[i]
  if arg in ("-o", "--output", "--max-time", "--max-redirs", "--proto", "--write-out", "--max-filesize"):
    value = args[i + 1]
    if arg in ("-o", "--output"): output = value
    if arg == "--write-out": write_out = True
    if arg == "--max-filesize": limit = int(value)
    if arg == "--max-time": budget = float(value)
    i += 2
  elif arg.startswith("-"):
    follow |= arg == "--location" or (not arg.startswith("--") and "L" in arg)
    i += 1
  else:
    url = arg
    i += 1

fixtures = json.loads(Path(os.environ["CURL_FIXTURES"]).read_text())
for hop in range(10):
  with open(os.environ["CURL_REQUESTS"], "a") as log:
    log.write(json.dumps({"url": url, "args": args, "budget": budget, "page_limit": limit}) + "\n")
  response = fixtures.get(url, {"status": 404})
  time.sleep(response.get("delay", 0))
  status = response.get("status", 200)
  target = urljoin(url, response.get("location", "")) if response.get("location") else ""
  if follow and status in (301, 302, 303, 307, 308) and target:
    url = target
    continue
  if response.get("exit") or status >= 400:
    sys.exit(response.get("exit", 22))
  body = Path(os.environ["ICON_FIXTURE"]).read_bytes() if response.get("image") else response.get("body", "").encode()
  if limit is not None and len(body) > limit:
    sys.exit(63)
  if output and not response.get("omit_body"):
    Path(output).write_bytes(body)
  elif not output:
    sys.stdout.buffer.write(body)
  if write_out:
    if "metadata" in response:
      sys.stdout.write(response["metadata"])
    else:
      sys.stdout.write(json.dumps({"http_code": status, "url_effective": url, "redirect_url": target}))
  sys.exit(0)
sys.exit(47)
''')
(stub_bin / "gtk-update-icon-cache").write_text("#!/bin/bash\nexit 0\n")
for stub in stub_bin.iterdir():
  stub.chmod(0o755)

site = "https://app.example.test/section/start"
well_known = "https://app.example.test/apple-touch-icon.png"
google = "https://www.google.com/s2/favicons?domain=app.example.test&sz=256"
public_icon = "https://icons.example.test/icon.png"
counter = 0

def fail(description, detail=""):
  print(detail, file=sys.stderr)
  print("not ok - " + description, file=sys.stderr)
  sys.exit(1)

def check(condition, description, detail=""):
  if not condition:
    fail(description, detail)

def passed(description):
  print("ok - " + description, flush=True)

def run(responses, expected, icon="", success=True, app=site, destination_kind="file"):
  global counter
  counter += 1
  directory = work / str(counter)
  home = directory / "home"
  icon_path = home / ".local/share/icons/hicolor/256x256/apps/example.png"
  icon_path.parent.mkdir(parents=True)
  old_image = image + b"old icon"
  if destination_kind == "directory":
    icon_path.mkdir()
    (icon_path / "marker").write_bytes(b"preserved")
  elif destination_kind == "directory-symlink":
    separate = directory / "separate"
    separate.mkdir()
    (separate / "marker").write_bytes(b"preserved")
    icon_path.symlink_to(separate, target_is_directory=True)
  else:
    icon_path.write_bytes(old_image)
    if destination_kind == "readonly-file":
      icon_path.chmod(0o444)
  fixtures = directory / "responses.json"
  fixtures.write_text(json.dumps(responses))
  requests = directory / "requests.jsonl"
  env = {**os.environ, "HOME": str(home), "OMARCHY_PATH": str(root),
    "PATH": str(stub_bin) + ":" + os.environ["PATH"],
    "CURL_FIXTURES": str(fixtures), "CURL_REQUESTS": str(requests), "ICON_FIXTURE": str(work / "image.png")}
  command = ["bash", str(root / "bin/omarchy-webapp-install"), "Example", app, icon, "", ""]
  if destination_kind == "readonly-file":
    terminal, terminal_input = pty.openpty()
    try:
      # A requested replacement must not prompt or leave the old icon when
      # terminal input would otherwise decline replacing a read-only file.
      os.write(terminal, b"n\n")
      result = subprocess.run(command, stdin=terminal_input, env=env, capture_output=True, text=True, timeout=20)
    finally:
      os.close(terminal_input)
      os.close(terminal)
  else:
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
  records = [json.loads(line) for line in requests.read_text().splitlines()] if requests.exists() else []
  urls = [record["url"] for record in records]
  check(urls == expected, "icon download requests only the checked destinations", repr(urls))
  check((result.returncode == 0) == success, "icon download reports the expected result", result.stdout + result.stderr)
  launcher = home / ".local/share/applications/Example.desktop"
  check(launcher.exists() == success, "failed icon download creates no launcher", result.stdout + result.stderr)
  if success and expected:
    check(not icon_path.is_symlink(), "icon download publishes the destination entry")
    check(icon_path.read_bytes() == image, "icon download publishes the terminal image")
  elif destination_kind == "directory":
    check(icon_path.is_dir() and [entry.name for entry in icon_path.iterdir()] == ["marker"]
      and (icon_path / "marker").read_bytes() == b"preserved", "icon download preserves an existing destination directory")
  elif not success:
    check(icon_path.read_bytes() == old_image, "failed candidate preserves the existing icon")
  if destination_kind == "directory-symlink":
    check([entry.name for entry in separate.iterdir()] == ["marker"]
      and (separate / "marker").read_bytes() == b"preserved", "icon download leaves a replaced directory symlink's target untouched")
  check(not list(icon_path.parent.glob("example.png.*")), "icon download cleans temporary candidates")
  return records, result

for reference in ("http://127.0.0.1/icon.png", "//10.0.0.1/icon.png", "javascript:ignored", "data:image/png,ignored"):
  run({site: {"body": f'<link rel="apple-touch-icon" href="{reference}">'}, well_known: {"image": True}}, [site, well_known])
passed("discovered private and non-HTTP icon references are skipped before curl")

# Cover every request boundary, including the two automatic fallback sources.
for boundary in ("page", "explicit", "discovered", "well-known", "google"):
  for target in ("http://127.0.0.1/icon.png", "ftp://icons.example.test/icon.png"):
    responses = {site: {}, well_known: {"image": True}, google: {"image": True}}
    if boundary == "page":
      responses[site] = {"status": 302, "location": target}
      expected, icon, success = [site, well_known], "", True
    elif boundary == "explicit":
      responses[public_icon] = {"status": 302, "location": target}
      expected, icon, success = [public_icon], public_icon, False
    elif boundary == "discovered":
      responses[site] = {"body": f'<link rel="apple-touch-icon" href="{public_icon}">'}
      responses[public_icon] = {"status": 302, "location": target}
      expected, icon, success = [site, public_icon, well_known], "", True
    elif boundary == "well-known":
      responses[well_known] = {"status": 302, "location": target}
      expected, icon, success = [site, well_known, google], "", True
    else:
      responses[well_known] = {"status": 404}
      responses[google] = {"status": 302, "location": target}
      expected, icon, success = [site, well_known, google], "", False
    run(responses, expected, icon, success)
  passed(f"{boundary} redirects refuse private and non-HTTP targets before the next request")

final_page = "https://pages.example.test/moved/home.html"
relative_icon = "https://pages.example.test/moved/images/touch.png"
cdn_icon = "https://cdn.example.test/touch.png"
records, _ = run({site: {"status": 302, "location": final_page},
  final_page: {"body": '<link rel="apple-touch-icon" href="images/touch.png">'},
  relative_icon: {"status": 307, "location": cdn_icon}, cdn_icon: {"image": True}},
  [site, final_page, relative_icon, cdn_icon])
for index, record in enumerate(records):
  args = record["args"]
  check(args[0] == "-q" and "--globoff" in args and "--proto" in args
    and args[args.index("--proto") + 1] == "=http,https"
    and not any(arg == "--location" or (arg.startswith("-") and not arg.startswith("--") and "L" in arg) for arg in args),
    "all icon requests explicitly constrain curl without automatic following", repr(args))
  check(record["page_limit"] == (100000 if index < 2 else None), "only page requests enforce the page size bound")
passed("public cross-origin redirects and final-page-relative icons work with constrained curl")

next_icon = "https://icons.example.test/sub/next.png"
run({public_icon: {"status": 303, "location": "sub/next.png"}, next_icon: {"image": True}},
  [public_icon, next_icon], public_icon)
passed("relative public image redirects use curl's resolved target")

upper_icon = "HTTPS://cdn.example.test/icon.png"
joined_icon = "https://cdn.example.test/icon.png"
run({site: {"body": f'<link rel="apple-touch-icon" href="{upper_icon}">'}, joined_icon: {"image": True}},
  [site, joined_icon])
run({site: {"body": '<link rel="apple-touch-icon" href="//cdn.example.test/icon.png">'},
  "https://cdn.example.test/icon.png": {"image": True}}, [site, "https://cdn.example.test/icon.png"])
passed("discovered uppercase and protocol-relative public icons remain supported")

chain = [f"https://icons.example.test/{index}.png" for index in range(5)]
responses = {chain[index]: {"status": 302, "location": chain[index + 1]} for index in range(4)}
responses[chain[3]] = {"image": True}
run(responses, chain[:4], chain[0])
responses[chain[3]] = {"status": 308, "location": chain[4]}
run(responses, chain[:4], chain[0], False)
run({public_icon: {"status": 302, "location": public_icon}}, [public_icon] * 4, public_icon, False)
passed("three redirects succeed while a fourth redirect or loop fails finitely")

for response in ({"status": 302}, {"status": 404}, {"status": 500}, {"exit": 7},
  {"metadata": "not JSON"}, {"metadata": "[]"}, {"metadata": '{"http_code":true}'},
  {"metadata": '{"http_code":200,"url_effective":"not-a-url"}'}, {"body": ""},
  {"body": '{"http_code":200,"url_effective":"https://icons.example.test/","redirect_url":""}'}):
  run({public_icon: response}, [public_icon], public_icon, False)
passed("missing redirect targets and invalid, failed, empty or non-image terminal responses fail")

run({public_icon: {"status": 302, "location": next_icon, "image": True},
  next_icon: {"status": 204, "omit_body": True}}, [public_icon, next_icon], public_icon, False)
passed("an empty terminal response cannot reuse a redirect's image bytes")

run({site: {"body": '{"http_code":200,"redirect_url":"http://127.0.0.1/"}'
    + '<link rel="apple-touch-icon" href="images/touch.png">'},
  "https://app.example.test/section/images/touch.png": {"image": True}},
  [site, "https://app.example.test/section/images/touch.png"])
passed("JSON-looking page content stays separate from request metadata")

run({site: {"body": "x" * 100001 + '<link rel="apple-touch-icon" href="ignored.png">'},
  well_known: {"image": True}}, [site, well_known])
passed("oversized pages abort discovery and use a checked icon fallback")

run({public_icon: {"image": True}}, [public_icon], public_icon, False, destination_kind="directory")
passed("a destination directory is preserved and cannot count as an installed icon")
run({public_icon: {"image": True}}, [public_icon], public_icon, destination_kind="directory-symlink")
passed("icon publication replaces a directory symlink entry without following its target")
run({public_icon: {"image": True}}, [public_icon], public_icon, destination_kind="readonly-file")
passed("icon publication replaces a read-only file even with terminal input present")

# Keep original total budgets across redirects, including a stub that sleeps
# longer than its remaining --max-time; the subprocess deadline enforces it.
slow_page = "https://pages.example.test/slow"
started = time.monotonic()
records, _ = run({site: {"status": 302, "location": slow_page, "delay": 3},
  slow_page: {"delay": 3, "body": f'<link rel="apple-touch-icon" href="{public_icon}">'},
  well_known: {"image": True}}, [site, slow_page, well_known])
check(records[1]["budget"] < 2 and time.monotonic() - started < 8, "page deadline is shared across hops")
passed("page requests preserve their five-second total deadline")

started = time.monotonic()
records, result = run({public_icon: {"status": 302, "location": next_icon, "delay": 6},
  next_icon: {"image": True, "delay": 6}}, [public_icon, next_icon], public_icon, False)
check(records[1]["budget"] < 4 and time.monotonic() - started < 13 and "timed out" in result.stderr,
  "icon deadline is shared across hops", result.stderr)
passed("icon requests preserve their ten-second total deadline")

run({}, [], "HEY", app="http://localhost:8080/")
run({}, [], str(work / "image.png"), app="http://127.0.0.1:8080/")
passed("bundled and local icons keep local web apps free of download checks")
PY
