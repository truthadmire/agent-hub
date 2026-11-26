#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/AgentHub.iconset"
xcrun swiftc -module-cache-path "$work/modules" Packaging/DrawIcon.swift -o "$work/draw"
for size in 16 32 128 256 512; do
  "$work/draw" "$size" "$work/AgentHub.iconset/icon_${size}x${size}.png"
  "$work/draw" "$((2*size))" "$work/AgentHub.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$work/AgentHub.iconset" -o Packaging/AgentHub.icns
