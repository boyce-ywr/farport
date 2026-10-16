#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native; fi
for language in zh-Hans en; do
  for screen in monitor-sorting terminal-clipboard; do
    workspace=$(mktemp -d "$PWD/.test/$screen-$language.XXXXXX")
    if [ "${1:-}" = "--ssh" ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
    FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN="$screen" \
      SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 "$app"
  done
done
