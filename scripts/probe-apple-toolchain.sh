#!/usr/bin/env bash
set -euo pipefail

# Inventory only: no downloads, installation, project generation, build, device
# boot, global xcode-select switch, or repository writes. JSON goes to stdout.
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\n' 'Usage: bash scripts/probe-apple-toolchain.sh [Xcode.app-or-Developer-directory ...]' \
    'Without arguments, inspect installed Xcode apps and the configured baseline.' \
    'A successful probe is not an application build or device validation.'
  exit 0
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Apple toolchain inspection requires macOS. No files or settings were changed.' >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT/config/toolchain.json" "$@" <<'PY'
import datetime
import glob
import json
import os
import pathlib
import subprocess
import sys

config = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))


def inspect(command, developer_directory=None):
    environment = os.environ.copy()
    if developer_directory is not None:
        environment["DEVELOPER_DIR"] = developer_directory
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=45)
        return {"exitCode": result.returncode, "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"exitCode": None, "stdout": "", "stderr": str(error)}


requested = sys.argv[2:]
if not requested:
    requested = glob.glob("/Applications/Xcode*.app/Contents/Developer")
    requested.append(config["developerDirectory"])
    if os.environ.get("DEVELOPER_DIR"):
        requested.append(os.environ["DEVELOPER_DIR"])

directories = set()
for candidate in requested:
    path = pathlib.Path(candidate).expanduser()
    if path.suffix == ".app":
        path = path / "Contents" / "Developer"
    directories.add(str(path.resolve()))

installations = []
for directory in sorted(directories):
    item = {"developerDirectory": directory, "exists": pathlib.Path(directory).is_dir()}
    if item["exists"]:
        item["xcode"] = inspect(["/usr/bin/xcodebuild", "-version"], directory)
        item["swift"] = inspect(["/usr/bin/xcrun", "swift", "--version"], directory)
        item["sdkList"] = inspect(["/usr/bin/xcodebuild", "-showsdks"], directory)
        item["iphoneOSSDK"] = inspect(["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-version"], directory)
        item["iphoneOSSDKBuild"] = inspect(["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"], directory)
        runtimes = inspect(["/usr/bin/xcrun", "simctl", "list", "runtimes", "--json"], directory)
        item["simulatorRuntimes"] = runtimes
        if runtimes["exitCode"] == 0:
            try:
                item["simulatorRuntimes"] = {"exitCode": 0, "data": json.loads(runtimes["stdout"])}
            except json.JSONDecodeError:
                pass  # Retain the exact tool response if it is not valid JSON.
    installations.append(item)

report = {
    "observedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "probeOnly": True,
    "applicationBuildValidated": False,
    "host": inspect(["/usr/bin/sw_vers"]),
    "architecture": inspect(["/usr/bin/uname", "-m"]),
    "imageOS": os.environ.get("ImageOS"),
    "imageVersion": os.environ.get("ImageVersion"),
    "activeDeveloperDirectory": inspect(["/usr/bin/xcode-select", "-p"]),
    "configuredBaseline": {key: config[key] for key in (
        "xcodeVersion", "xcodeBuild", "appleSwiftVersion", "iosSDKVersion", "simulatorRuntime"
    )},
    "installations": installations,
    "note": "Availability evidence only. A beta, preview image, or missing runtime does not validate the stable upgrade; no automatic selection or fallback is performed.",
}
print(json.dumps(report, ensure_ascii=False, indent=2))
if not any(item["exists"] for item in installations):
    raise SystemExit(1)
PY
