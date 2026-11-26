#!/bin/bash
# Run GUI checks only on an explicitly selected packaged Agent Hub.
set -euo pipefail
mode=offline
if [[ ${1:-} == --history ]]; then
  mode=history
  shift
elif [[ ${1:-} == --live-codex ]]; then
  mode=live
  shift
fi
if [[ $# -lt 2 || $# -gt 3 || ! -d "$1" || -e "$2" ]]; then
  echo 'usage: scripts/ui-smoke.sh [--history|--live-codex] "/path/to/Agent Hub.app" /new/evidence-directory [completed-example-data-directory]' >&2
  exit 2
fi
app=$(cd "$1" && pwd -P)
id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$id" == org.agenthub.desktop ]] || { echo "Unexpected bundle ID: $id" >&2; exit 2; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen to generate the UI-test harness.' >&2; exit 2; }
source_root=$(cd "$(dirname "$0")/../Tests/DesktopUI" && pwd -P)
mkdir -p "$2"
evidence=$(cd "$2" && pwd -P)
work=$(mktemp -d "/private/tmp/agent-hub-gui.XXXXXX")
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
if [[ "$mode" == live ]]; then
  [[ $# -eq 2 ]] || { echo 'The one-task live run accepts no other dataset.' >&2; exit 2; }
  provider=$(command -v codex)
  [[ -x "$provider" && "$provider" == /* ]] || { echo 'Codex CLI unavailable.' >&2; exit 2; }
  plutil -insert providerHome -string "$HOME" "$plist"
fi
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
cp "$source_root/Support/Capture.swift" "$work/main.swift"
swiftc "$work/main.swift" "$source_root/Support/NativeImport.swift" -o "$work/capture-window"
"$work/capture-window" "$app" "$capture_inbox" "$evidence" "$repo" "$work"
mkdir -p "$work/fixture"
printf '%s
' "$capture_inbox" > "$work/fixture/history-inbox"
install -m 755 "$source_root/Support/OfflineCodex.py" "$work/fixture/codex"
provider=${provider:-"$work/fixture/codex"}
python3 - "$work/data/agent-hub.sqlite3" "$repo" "$provider" <<'PYCHECK'
import json, os, sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    projects = db.execute("select path from projects").fetchall()
    config = dict(roles={"lead": "codex", "backend": "codex"}, models={}, providerConcurrency={},
                  executableOverrides={"codex": sys.argv[3], "antigravity":sys.argv[2]+"/missing-agy","dsh":sys.argv[2]+"/missing-dsh"}, enabledRoles=["lead", "backend"],
                  disabledProviders=["antigravity", "dsh"], maxAttempts=1, maxConcurrent=1,
                  maxRetries=0, maxRepairs=0, maxSeconds=300, paidProviders=[], allowedFallbacks=[],
                  verificationCommands=[["/usr/bin/grep", "-Fx", "verified", "status.txt"]])
    db.execute("insert or replace into config(id,payload) values(?,?)", ("global",json.dumps(config).encode()))
if len(projects) != 1 or not os.path.samefile(projects[0][0], sys.argv[2]):
    raise SystemExit("The imported directory did not match the test Git repository.")
PYCHECK
"$work/capture-window" "$app" "$capture_inbox" "$evidence" "$repo" &
capture_pid=$!
trap 'kill "$capture_pid" 2>/dev/null || true' EXIT
selection=()
if [[ "$mode" == live ]]; then
  selection+=(-only-testing:DesktopUI/DesktopUITests/testLiveCodexOnce)
elif [[ "$mode" == history ]]; then
  selection+=(-only-testing:DesktopUI/DesktopUITests/testReadingWhileAgentWrites)
else
  selection+=(-skip-testing:DesktopUI/DesktopUITests/testLiveCodexOnce -skip-testing:DesktopUI/DesktopUITests/testReadingWhileAgentWrites)
fi
xcodebuild "${selection[@]}" -xctestrun "${plans[0]}" -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath "$evidence/desktop.xcresult" test-without-building
