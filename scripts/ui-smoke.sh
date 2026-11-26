#!/bin/bash
# Run GUI checks only on an explicitly selected packaged Agent Hub.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 || ! -d "$1" || -e "$2" ]]; then
  echo 'usage: scripts/ui-smoke.sh "/path/to/Agent Hub.app" /new/evidence-directory [completed-example-data-directory]' >&2
  exit 2
fi
app=$(cd "$1" && pwd -P)
id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$id" == org.agenthub.desktop ]] || { echo "Unexpected bundle ID: $id" >&2; exit 2; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen to generate the UI-test harness.' >&2; exit 2; }
source_root=$(cd "$(dirname "$0")/../Tests/DesktopUI" && pwd -P)
mkdir -p "$2"
evidence=$(cd "$2" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-gui.XXXXXX")
mkdir -p "$work/Tests" "$work/data" "$work/home/"{Desktop,Documents,Downloads,Library/Preferences,Library/Caches} "$work/Field Notes"
cp "$source_root/"*.swift "$work/Tests/"
cp "$source_root/project.yml" "$work/"
repo="$work/Field Notes"
git -C "$repo" init -q -b main
printf 'pending\n' > "$repo/status.txt"
git -C "$repo" add -- status.txt
git -C "$repo" -c user.name='Desktop QA' -c user.email='qa@example.invalid' -c commit.gpgsign=false commit -qm 'Initial test file'
plist="$work/Tests/Run.plist"
plutil -create xml1 "$plist"
plutil -insert app -string "$app" "$plist"
plutil -insert work -string "$work" "$plist"
plutil -insert evidence -string "$evidence" "$plist"
# The XCTest runner has a standard macOS sandbox. Its own local temporary
# directory lets it request screenshots without a filesystem entitlement.
capture_inbox="$HOME/Library/Containers/org.agenthub.desktop.uitests.xctrunner/Data/tmp/$(basename "$work")"
plutil -insert captureInbox -string "$capture_inbox" "$plist"
if [[ $# -eq 3 ]]; then
  gallery=$(cd "$3" && pwd -P)
  mkdir -p "$work/gallery-state"
  gallery_title=$(python3 - "$gallery" "$work/gallery-state" <<'PYFIXTURE'
from pathlib import Path
import json, sqlite3, sys
source = Path(sys.argv[1]) / "agent-hub.sqlite3"
target = Path(sys.argv[2]) / "agent-hub.sqlite3"
with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as original:
    tasks = [json.loads(row[0]) for row in original.execute("select payload from tasks")]
    if len(tasks) != 1 or tasks[0]["title"] not in ("fixture-gallery", "live-team") or tasks[0]["state"] != "completed":
        raise SystemExit("Expected a completed HubSmoke gallery or live-team example with exactly one task.")
    with sqlite3.connect(target) as copy:
        original.backup(copy)
    print(tasks[0]["title"])
PYFIXTURE
  )
  plutil -insert galleryTitle -string "$gallery_title" "$plist"
  plutil -insert gallery -string "$work/gallery-state" "$plist"
fi
cd "$work"
xcodegen generate --spec project.yml
echo "UI test sandbox: $work"
xcodebuild -quiet -project DesktopUI.xcodeproj -scheme DesktopUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$work/build" build-for-testing
plans=("$work"/build/Build/Products/*.xctestrun)
[[ ${#plans[@]} -eq 1 && -f "${plans[0]}" ]]
# Keep only the screenshots explicitly taken of our application's windows by the test.
plutil -replace DesktopUI.PreferredScreenCaptureFormat -string screenshots "${plans[0]}"
plutil -replace DesktopUI.SystemAttachmentLifetime -string keepNever "${plans[0]}"
swiftc "$source_root/Support/Capture.swift" -o "$work/capture-window"
"$work/capture-window" "$app" "$capture_inbox" "$evidence" &
capture_pid=$!
trap 'kill "$capture_pid" 2>/dev/null || true' EXIT
xcodebuild -xctestrun "${plans[0]}" -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath "$evidence/desktop.xcresult" test-without-building
