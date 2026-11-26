#!/bin/bash
set -euo pipefail
app=${1:?"usage: verify-app.sh APP adhoc|developer-id"}
mode=${2:?}
plist="$app/Contents/Info.plist"
[[ "$mode" = adhoc || "$mode" = developer-id ]] || exit 2
[[ "$(plutil -extract CFBundleIdentifier raw "$plist")" = org.agenthub.desktop ]]
[[ "$(plutil -extract CFBundleExecutable raw "$plist")" = AgentHub ]]
[[ "$(plutil -extract LSMinimumSystemVersion raw "$plist")" = 14.0 ]]
[[ -s "$app/Contents/Resources/AgentHub.icns" ]]
[[ -s "$app/Contents/Resources/LICENSE" && -s "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
# Fail if an unexpected helper or dependency is added without packaging review.
expected=(Contents/Helpers/HubProcessGuard Contents/MacOS/AgentHub)
count=0
while IFS= read -r -d '' path; do
  if file -b "$path" | grep -q 'Mach-O'; then
    case "${path#"$app/"}" in
      Contents/Helpers/HubProcessGuard|Contents/MacOS/AgentHub) count=$((count + 1)) ;;
      *) echo "Unexpected executable in bundle: $path" >&2; exit 1 ;;
    esac
  fi
done < <(find "$app" -type f -print0)
[[ "$count" = 2 ]]
for relative in "${expected[@]}"; do
  binary="$app/$relative"
  [[ -x "$binary" && "$(lipo -archs "$binary")" = arm64 ]]
  xcrun vtool -show-build "$binary" | awk '$1 == "minos" && $2 ~ /^14\.0(\.0)?$/{seen=1} END{exit !seen}'
  otool -L "$binary" | awk 'NR>1 && $1 !~ /^\/System\/Library\// && $1 !~ /^\/usr\/lib\// {print "Unbundled dependency:",$1; fail=1} END {exit fail}'
  otool -l "$binary" | awk '$1=="cmd"{r=($2=="LC_RPATH")} r && $1=="path" && $2!="/usr/lib/swift"{print "Unexpected rpath:",$0; fail=1} END{exit fail}'
  codesign --verify --strict --verbose=2 "$binary"
done
codesign --verify --deep --strict --verbose=2 "$app"
if [[ "$mode" = developer-id ]]; then
  : "${APPLE_TEAM_ID:?Set the expected Developer Team ID}"
  [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 2
  for item in "$app/Contents/Helpers/HubProcessGuard" "$app"; do
    codesign --verify --strict -R "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\"" "$item"
    details=$(codesign -dv --verbose=4 "$item" 2>&1)
    [[ "$details" = *"runtime)"* && "$details" = *"Timestamp="* ]]
    # No special privileges or debugging entitlements are needed by either binary.
    [[ -z "$(codesign -d --entitlements - "$item" 2>/dev/null)" ]]
  done
fi
