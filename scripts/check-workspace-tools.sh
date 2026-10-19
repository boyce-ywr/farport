#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native; fi
mkdir -p .test
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/workspace-tools-$language.XXXXXX")
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=workspace-tools \
    SWB_QA_OUTPUT="$workspace/commands.png" SWB_QA_EXIT=1 "$app"
done
