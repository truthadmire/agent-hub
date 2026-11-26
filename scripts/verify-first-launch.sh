#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 || ! -d "$1/Contents/MacOS" ]]; then
  echo 'Usage: scripts/verify-first-launch.sh "/path/to/Agent Hub.app"' >&2
  exit 2
fi
source_app=$1
repository=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/agenthub-first-launch.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Applications"
installed="$work/Applications/Agent Hub.app"
ditto "$source_app" "$installed"
xcrun swiftc -parse-as-library "$repository/Tests/DesktopUI/Support/FirstLaunch.swift" -o "$work/check-first-launch"
"$work/check-first-launch" "$installed" "$work/data"
