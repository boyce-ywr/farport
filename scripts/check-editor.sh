#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
mkdir -p .test/ui-regression
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/editor-$language.XXXXXX")
  if [ "${1:-}" = "--ssh" ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=editor-actions \
  SWB_QA_OUTPUT="$PWD/.test/ui-regression/editor-$language.png" SWB_QA_EXIT=1 "$app"
done
