#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native; fi
mkdir -p .test
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/workflow-refinements-$language.XXXXXX")
  if [ "${1:-}" = --ssh ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=workflow-refinements \
    SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 "$app"
done
