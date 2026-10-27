#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
mkdir -p .test
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/tmux-copy-$language.XXXXXX")
  if [ "${1:-}" = --ssh ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=tmux-copy \
    SWB_QA_REQUIRE_SSH="$([ "${1:-}" = --ssh ] && echo 1 || echo 0)" \
    SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES "$app"
done
