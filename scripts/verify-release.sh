#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:?"usage: verify-release.sh local|signed|release DMG"}
dmg=${2:?}
[[ -f "$dmg" ]]
case "$mode" in local) identity=adhoc ;; signed|release) identity=developer-id ;; *) exit 2 ;; esac
if [[ "$mode" != local ]]; then
  : "${APPLE_TEAM_ID:?Set the expected Developer Team ID}"
  [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 2
  codesign --verify --strict -R "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\"" "$dmg"
fi
if [[ "$mode" = release ]]; then
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi
hdiutil verify "$dmg"
scratch=$(mktemp -d)
mount="$scratch/mount"
copied="$scratch/install/Agent Hub.app"
mkdir -p "$mount" "$scratch/install"
mounted=0
cleanup() {
  if ((mounted)); then
    if ! hdiutil detach "$mount" > /dev/null; then
      echo "Volume still mounted at $mount" >&2
      return
    fi
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg"
mounted=1
[[ -L "$mount/Applications" && "$(readlink "$mount/Applications")" = /Applications ]]
ditto "$mount/Agent Hub.app" "$copied"
hdiutil detach "$mount"
mounted=0
./scripts/verify-app.sh "$copied" "$identity"
if [[ "$mode" = release ]]; then
  xcrun stapler validate "$copied"
  spctl --assess --type execute --verbose=2 "$copied"
fi
echo 'Verified DMG, Applications link and copied app.'
