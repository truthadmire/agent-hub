#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-run}
case "$mode" in run|--debug|--logs|--telemetry|--verify) ;; *) echo 'usage: build_and_run.sh [--debug|--logs|--telemetry|--verify]' >&2; exit 2 ;; esac
dir="$PWD/dist/development"
app="$dir/Agent Hub.app"
mkdir -p "$dir"
tmp=$(mktemp -d "$dir/.build.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
./scripts/bundle.sh debug "$tmp" adhoc
# Terminate only the development copy launched from this checkout.
while IFS= read -r pid; do
  if [[ "$(ps -p "$pid" -o comm=)" = "$app/Contents/MacOS/AgentHub" ]]; then kill -TERM "$pid"; fi
done < <(pgrep -x AgentHub || true)
if [[ -e "$app" ]]; then mv "$app" "$tmp/previous.app"; fi
mv "$tmp/Agent Hub.app" "$app"
case "$mode" in
  --debug) lldb -- "$app/Contents/MacOS/AgentHub" ;;
  --logs) open -n "$app"; /usr/bin/log stream --info --predicate 'process == "AgentHub"' ;;
  --telemetry) open -n "$app"; /usr/bin/log stream --info --predicate 'subsystem == "org.agenthub.desktop"' ;;
  --verify)
    open -n "$app"
    for ((i=0; i<25; i++)); do
      while IFS= read -r pid; do
        if [[ "$(ps -p "$pid" -o comm=)" = "$app/Contents/MacOS/AgentHub" ]]; then echo "Agent Hub running (PID $pid)"; exit 0; fi
      done < <(pgrep -x AgentHub || true)
      sleep 0.2
    done
    echo 'Agent Hub did not stay running' >&2; exit 1 ;;
  run) open -n "$app" ;;
esac
