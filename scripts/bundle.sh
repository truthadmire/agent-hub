#!/bin/bash
# Build only the two executable products and the explicitly listed resources.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
config=${1:-release}
output=${2:?"usage: bundle.sh debug|release DIRECTORY [adhoc|developer-id]"}
signing=${3:-adhoc}
[[ "$config" = debug || "$config" = release ]] || exit 2
[[ "$signing" = adhoc || "$signing" = developer-id ]] || exit 2
app="$output/Agent Hub.app"
[[ ! -e "$app" ]] || { echo "Bundle already exists: $app" >&2; exit 2; }
flags=(--configuration "$config" --arch arm64)
if [[ -n "${SWIFTPM_SCRATCH_PATH:-}" ]]; then flags+=(--scratch-path "$SWIFTPM_SCRATCH_PATH"); fi
if [[ "$config" = release ]]; then
  flags+=(-Xswiftc -file-prefix-map -Xswiftc "$root=." -Xcc "-ffile-prefix-map=$root=.")
  if swift build --help | awk 'index($0,"-debug-info-format"){found=1} END{exit !found}'; then
    flags+=(-debug-info-format none)
  fi
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
for product in AgentHub HubProcessGuard; do
  swift build "${flags[@]}" --product "$product"
done
bin=$(swift build "${flags[@]}" --show-bin-path)
mkdir -p "$output"
stage=$(mktemp -d "$output/.bundle.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Agent Hub.app"
mkdir -p "$bundle/Contents/"{MacOS,Helpers,Resources}
install -m 755 "$bin/AgentHub" "$bundle/Contents/MacOS/AgentHub"
install -m 755 "$bin/HubProcessGuard" "$bundle/Contents/Helpers/HubProcessGuard"
install -m 644 Packaging/Info.plist "$bundle/Contents/Info.plist"
install -m 644 Packaging/AgentHub.icns "$bundle/Contents/Resources/AgentHub.icns"
install -m 644 LICENSE THIRD_PARTY_NOTICES.md "$bundle/Contents/Resources"
if [[ -n "${AGENT_HUB_REPOSITORY_URL:-}" ]]; then
  [[ "$AGENT_HUB_REPOSITORY_URL" =~ ^https://github\.com/[A-Za-z0-9.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Expected a canonical GitHub repository URL' >&2; exit 2; }
  plutil -insert AgentHubRepositoryURL -string "$AGENT_HUB_REPOSITORY_URL" "$bundle/Contents/Info.plist"
fi
plutil -lint "$bundle/Contents/Info.plist"
# Some SDK versions add toolchain and cryptex directories to the default rpath.
# Both shipped products link only to system libraries at absolute install names.
for binary in "$bundle/Contents/MacOS/AgentHub" "$bundle/Contents/Helpers/HubProcessGuard"; do
  while IFS= read -r rpath; do
    if [[ "$rpath" != /usr/lib/swift ]]; then
      install_name_tool -delete_rpath "$rpath" "$binary"
    fi
  done < <(otool -l "$binary" | awk '$1=="cmd"{r=($2=="LC_RPATH")} r && $1=="path"{sub(/^[[:space:]]*path /,""); sub(/ \(offset [0-9]+\)$/,""); print; r=0}')
done
# A release bundle contains no debug symbol tables or private source paths.
if [[ "$config" = release ]]; then
  for binary in "$bundle/Contents/MacOS/AgentHub" "$bundle/Contents/Helpers/HubProcessGuard"; do
    strip -S -x "$binary"
    if /usr/bin/strings -a "$binary" | /usr/bin/awk -v p="$root" 'index($0,p){found=1} END{exit !found}'; then
      echo "Private source path in $(basename "$binary")" >&2; exit 1
    fi
  done
fi
options=(--force)
if [[ "$signing" = developer-id ]]; then
  : "${DEVELOPER_ID_IDENTITY:?Set the exact Developer ID Application signing name or fingerprint}"
  : "${APPLE_TEAM_ID:?Set the expected Developer Team ID}"
  [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 2
  options+=(--options runtime --timestamp --sign "$DEVELOPER_ID_IDENTITY")
  if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then options+=(--keychain "$SIGNING_KEYCHAIN"); fi
else
  options+=(--timestamp=none --sign -)
fi
codesign "${options[@]}" --identifier org.agenthub.desktop.process-guard "$bundle/Contents/Helpers/HubProcessGuard"
codesign "${options[@]}" "$bundle"
"$root/scripts/verify-app.sh" "$bundle" "$signing"
mv "$bundle" "$app"
echo "Built $app ($signing)"
