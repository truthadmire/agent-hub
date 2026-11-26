#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
mode=${1:?"usage: release.sh local|signed|release [--resume]"}
resume=${2:-}
[[ -z "$resume" || "$resume" = --resume ]] || exit 2
case "$mode" in
  local) signing=adhoc; suffix=-local ;;
  signed) signing=developer-id; suffix=-signed-pending-notarization ;;
  release) signing=developer-id; suffix= ;;
  *) exit 2 ;;
esac
if [[ "$signing" = developer-id ]]; then
  : "${DEVELOPER_ID_IDENTITY:?Set DEVELOPER_ID_IDENTITY}"
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
fi
if [[ "$mode" = release && -z "${NOTARY_PROFILE:-}" && -z "${NOTARY_KEY_PATH:-}" ]]; then
  echo 'Set NOTARY_PROFILE or NOTARY_KEY_PATH for a notarized release.' >&2; exit 2
fi
version=$(plutil -extract CFBundleShortVersionString raw Packaging/Info.plist)
build=$(plutil -extract CFBundleVersion raw Packaging/Info.plist)
name="AgentHub-$version-arm64$suffix"
destination="${AGENT_HUB_OUTPUT_DIR:-$root/dist/$mode/$version}"
work="$destination.in-progress"
assets="$work/assets"
app="$work/Agent Hub.app"
dmg="$assets/$name.dmg"
mkdir -p "$(dirname "$destination")"
if [[ -e "$destination" ]]; then echo "Output already exists: $destination" >&2; exit 2; fi
lock="$work.lock"
mkdir "$lock" || { echo "Another build owns $lock" >&2; exit 2; }
trap 'rmdir "$lock"' EXIT
if [[ -n "$resume" ]]; then
  [[ -d "$work" && -f "$work/mode" && "$(cat "$work/mode")" = "$mode" ]] || { echo 'No matching in-progress package' >&2; exit 2; }
else
  mkdir "$work" || { echo "Use --resume to continue $work" >&2; exit 2; }
  printf '%s\n' "$mode" > "$work/mode"
fi
mkdir -p "$assets" "$work/notary"
if [[ ! -d "$app" ]]; then
  commit=$(git rev-parse --verify HEAD 2>/dev/null || true)
  tree=unversioned
  if [[ -n "$commit" ]]; then
    if [[ -z "$(git status --porcelain)" ]]; then tree=clean; else tree=dirty; fi
  fi
  jq -n --arg version "$version" --arg build "$build" --arg mode "$mode" \
    --arg commit "$commit" --arg tree "$tree" --arg macOS "$(sw_vers -productVersion)" \
    --arg xcode "$(xcodebuild -version)" --arg swift "$(swift --version 2>&1)" \
    '{version:$version,build:$build,architecture:"arm64",minimumMacOS:"14.0",distribution:$mode,commit:$commit,worktree:$tree,buildSystem:$macOS,xcode:$xcode,swift:$swift}' > "$assets/build.json"
  if [[ -f CHANGELOG.md ]]; then cp CHANGELOG.md "$assets/RELEASE-NOTES.md"; fi
  ./scripts/bundle.sh release "$work" "$signing"
fi
./scripts/verify-app.sh "$app" "$signing"
[[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ]]
[[ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$build" ]]
if [[ "$mode" = release ]]; then
  if [[ ! -f "$work/payload.zip" ]]; then
    ditto -c -k --keepParent "$app" "$work/payload.tmp.zip"
    mv "$work/payload.tmp.zip" "$work/payload.zip"
  fi
  ./scripts/notarize.sh "$work/payload.zip" "$app" "$work/notary/app"
  cp "$work/notary/app.json" "$assets/notarization-app.json"
fi
if [[ ! -f "$dmg" ]]; then
  mkdir -p "$work/volume"
  ditto "$app" "$work/volume/Agent Hub.app"
  if [[ ! -L "$work/volume/Applications" ]]; then ln -s /Applications "$work/volume/Applications"; fi
  hdiutil create -volname 'Agent Hub' -fs HFS+ -format UDZO -srcfolder "$work/volume" -ov "$work/staged.dmg"
  if [[ "$signing" = developer-id ]]; then
    opts=(--force --sign "$DEVELOPER_ID_IDENTITY" --timestamp)
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then opts+=(--keychain "$SIGNING_KEYCHAIN"); fi
    codesign "${opts[@]}" --identifier org.agenthub.desktop.dmg "$work/staged.dmg"
  fi
  mv "$work/staged.dmg" "$dmg"
fi
if [[ "$mode" = release ]]; then
  ./scripts/notarize.sh "$dmg" "$dmg" "$work/notary/dmg"
  cp "$work/notary/dmg.json" "$assets/notarization-dmg.json"
fi
./scripts/verify-release.sh "$mode" "$dmg"
(cd "$assets" && shasum -a 256 "$name.dmg" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt)
# Keep a convenient copy of the actual app whose bytes went into the DMG.
ditto "$app" "$assets/Agent Hub.app"
mv "$assets" "$destination"
rm -rf "$work"
echo "Verified package at $destination"
