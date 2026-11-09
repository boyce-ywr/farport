#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test/ui-regression
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/terminal-path-links.XXXXXX")
  if [ "${1:-}" = "--ssh" ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=terminal-path-links SWB_QA_OUTPUT="$PWD/.test/ui-regression/terminal-path-links-$language.png" \
    SWB_QA_APPEARANCE=dark SWB_QA_EXIT=1 NSUnbufferedIO=YES "$app"
done
