#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --product HubProcessGuard
swift build --product HubSmoke
bin=$(swift build --show-bin-path)
exec "$bin/HubSmoke" "$@"
