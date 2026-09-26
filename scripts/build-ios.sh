#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'This script requires macOS and the pinned Xcode. On Windows use scripts/test-core.ps1.' >&2
  exit 1
fi

config() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' \
    "$ROOT/config/toolchain.json" "$1"
}

export DEVELOPER_DIR="$(config developerDirectory)"
EXPECTED_XCODE="$(config xcodeVersion)"
EXPECTED_BUILD="$(config xcodeBuild)"
EXPECTED_SDK="$(config iosSDKVersion)"
SIMULATOR_RUNTIME="$(config simulatorRuntime)"
XCODEGEN_VERSION="$(config xcodegenVersion)"
RUN_DIR="$ROOT/build/ios/$(date -u +%Y%m%dT%H%M%SZ)-$$"
ARTIFACTS="$RUN_DIR/artifacts"
LOGS="$RUN_DIR/logs"
mkdir -p "$ARTIFACTS" "$LOGS"
cp "$ROOT/config/toolchain.json" "$ARTIFACTS/toolchain-config.json"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  printf 'Required Xcode is unavailable: %s\n' "$DEVELOPER_DIR" | tee "$LOGS/toolchain-error.log" >&2
  exit 1
fi

XCODE_ACTUAL="$(xcodebuild -version)"
printf '%s\n' "$XCODE_ACTUAL" | tee "$LOGS/xcode-version.log"
if [[ "$XCODE_ACTUAL" != "$(printf 'Xcode %s\nBuild version %s' "$EXPECTED_XCODE" "$EXPECTED_BUILD")" ]]; then
  printf '%s\n' 'Xcode differs from config/toolchain.json; review the baseline instead of silently switching.' >&2
  exit 1
fi
SDK_ACTUAL="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "$SDK_ACTUAL" != "$EXPECTED_SDK" ]]; then
  printf 'Expected iOS SDK %s, found %s.\n' "$EXPECTED_SDK" "$SDK_ACTUAL" >&2
  exit 1
fi
xcrun swift --version | tee "$LOGS/swift-version.log"
xcodebuild -showsdks > "$LOGS/sdks.log"
printf 'ImageOS=%s\nImageVersion=%s\n' "${ImageOS:-local}" "${ImageVersion:-local}" > "$LOGS/runner-image.log"

# Install only this checksum-verified release into the ignored project tool cache.
TOOL_DIR="$ROOT/.tools/XcodeGen-$XCODEGEN_VERSION"
TOOL_ARCHIVE="$TOOL_DIR/xcodegen.zip"
XCODEGEN="$TOOL_DIR/xcodegen/bin/xcodegen"
mkdir -p "$TOOL_DIR"
if [[ ! -x "$XCODEGEN" ]]; then
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "$(config xcodegenArchiveURL)" --output "$TOOL_ARCHIVE"
  printf '%s  %s\n' "$(config xcodegenArchiveSHA256)" "$TOOL_ARCHIVE" | shasum -a 256 -c -
  unzip -q -o "$TOOL_ARCHIVE" -d "$TOOL_DIR"
fi
XCODEGEN_ACTUAL="$("$XCODEGEN" --version)"
printf '%s\n' "$XCODEGEN_ACTUAL" | tee "$LOGS/xcodegen-version.log"
if [[ "$XCODEGEN_ACTUAL" != "Version: $XCODEGEN_VERSION" ]]; then
  printf '%s\n' 'Unexpected XcodeGen version.' >&2
  exit 1
fi

# macOS evaluates the Apple-only LedgerStore package targets as well as LedgerCore.
xcrun swift package resolve 2>&1 | tee "$LOGS/package-resolve.log"
if [[ ! -f "$ROOT/Package.resolved" ]]; then
  printf '%s\n' 'Apple dependency resolution did not produce Package.resolved.' >&2
  exit 1
fi
cp "$ROOT/Package.resolved" "$ARTIFACTS/Package.resolved"
python3 - "$ROOT/Package.resolved" "$(config grdbVersion)" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
grdb = [pin for pin in lock["pins"] if pin["identity"].lower() == "grdb.swift"]
if len(grdb) != 1 or grdb[0]["state"].get("version") != sys.argv[2]:
    raise SystemExit("Resolved GRDB does not match config/toolchain.json.")
PY
xcrun swift test --configuration debug --disable-automatic-resolution 2>&1 | tee "$LOGS/package-tests.log"
"$XCODEGEN" generate --spec "$ROOT/project.yml" 2>&1 | tee "$LOGS/project-generation.log"

XCODE_LOCK_DIR="$ROOT/Ledger.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$XCODE_LOCK_DIR"
cp "$ROOT/Package.resolved" "$XCODE_LOCK_DIR/Package.resolved"

xcrun simctl list devices available --json > "$LOGS/simulators.json"
SIMULATOR_ID="$(python3 - "$LOGS/simulators.json" "$SIMULATOR_RUNTIME" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1], encoding="utf-8"))["devices"].get(sys.argv[2], [])
phones = sorted(
    (device for device in devices if device.get("isAvailable") and device["name"].startswith("iPhone")),
    key=lambda device: (device["name"] != "iPhone 17 Pro Max", device["name"], device["udid"]),
)
if not phones:
    raise SystemExit("The pinned iOS simulator runtime has no available iPhone. Review toolchain.json.")
print(phones[0]["udid"])
PY
)"
printf 'runtime=%s\nudid=%s\n' "$SIMULATOR_RUNTIME" "$SIMULATOR_ID" > "$LOGS/selected-simulator.log"

TEST_STATUS=0
xcodebuild test \
  -project Ledger.xcodeproj -scheme Ledger -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -destination-timeout 180 -parallel-testing-enabled NO \
  -derivedDataPath "$RUN_DIR/DerivedData" \
  -resultBundlePath "$ARTIFACTS/AppTests.xcresult" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  2>&1 | tee "$LOGS/simulator-tests.log" || TEST_STATUS=$?

# Xcode 16+ has a dedicated attachment exporter. Preserve the current tool's
# help as evidence and export keepAlways UI screenshots even when tests fail.
ATTACHMENT_STATUS=0
if [[ -d "$ARTIFACTS/AppTests.xcresult" ]]; then
  mkdir -p "$ARTIFACTS/screenshots"
  xcrun xcresulttool help export attachments > "$LOGS/xcresult-attachments-help.log" 2>&1 || ATTACHMENT_STATUS=$?
  if [[ "$ATTACHMENT_STATUS" -eq 0 ]]; then
    xcrun xcresulttool export attachments \
      --path "$ARTIFACTS/AppTests.xcresult" --output-path "$ARTIFACTS/screenshots" \
      2>&1 | tee "$LOGS/attachment-export.log" || ATTACHMENT_STATUS=$?
  fi
  xcrun xcresulttool get test-results summary --path "$ARTIFACTS/AppTests.xcresult" \
    > "$ARTIFACTS/test-summary.json" 2> "$LOGS/test-summary-error.log" || true
fi
if [[ "$TEST_STATUS" -ne 0 ]]; then
  exit "$TEST_STATUS"
fi
if [[ "$ATTACHMENT_STATUS" -ne 0 ]]; then
  printf '%s\n' 'Tests passed, but screenshot attachment export failed.' >&2
  exit "$ATTACHMENT_STATUS"
fi
if ! find "$ARTIFACTS/screenshots" -type f -iname '*.png' -print -quit | grep -q .; then
  printf '%s\n' 'The UI smoke test produced no PNG attachment. Check its keepAlways screenshot.' >&2
  exit 1
fi

xcodebuild build \
  -project Ledger.xcodeproj -scheme Ledger -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$RUN_DIR/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  2>&1 | tee "$LOGS/device-build.log"

APP="$RUN_DIR/DerivedData/Build/Products/Release-iphoneos/Ledger.app"
PLATFORM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$APP/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
ARCHITECTURES="$(xcrun lipo -archs "$APP/$EXECUTABLE")"
if [[ "$PLATFORM" != "iPhoneOS" || "$BUNDLE_ID" != "$(config bundleIdentifier)" || "$ARCHITECTURES" != "arm64" ]]; then
  printf 'Invalid device product: platform=%s bundle=%s arch=%s\n' "$PLATFORM" "$BUNDLE_ID" "$ARCHITECTURES" >&2
  exit 1
fi
if [[ -e "$APP/embedded.mobileprovision" ]]; then
  printf '%s\n' 'Unexpected provisioning profile in unsigned product.' >&2
  exit 1
fi

mkdir -p "$RUN_DIR/package/Payload"
ditto "$APP" "$RUN_DIR/package/Payload/Ledger.app"
ditto -c -k --keepParent "$RUN_DIR/package/Payload" "$ARTIFACTS/Ledger-unsigned.ipa"
(
  cd "$ARTIFACTS"
  shasum -a 256 Ledger-unsigned.ipa > Ledger-unsigned.ipa.sha256
)
python3 - "$ARTIFACTS/build-metadata.json" "$SIMULATOR_ID" "$ARCHITECTURES" <<'PY'
import datetime
import json
import os
import sys

metadata = {
    "builtAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "sourceCommit": os.environ.get("GITHUB_SHA", "local-unversioned"),
    "githubRunID": os.environ.get("GITHUB_RUN_ID"),
    "simulatorUDID": sys.argv[2],
    "architectures": sys.argv[3],
    "status": "package tests and simulator tests passed; unsigned device build produced",
    "deviceInstallation": "not verified",
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(metadata, output, ensure_ascii=False, indent=2)
    output.write("\n")
PY
printf 'Unsigned IPA and build evidence: %s\n' "$ARTIFACTS"
