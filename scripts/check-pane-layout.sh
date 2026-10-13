#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
mkdir -p .test/ui-regression
workspace=$(mktemp -d "$PWD/.test/pane-layout.XXXXXX")
if [ -f .test/app/hosts.json ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
SWB_HOME="$workspace" SWB_QA_OUTPUT="$PWD/.test/ui-regression/pane-layout.png" \
SWB_QA_SCREEN=pane-layout SWB_QA_APPEARANCE=dark SWB_QA_EXIT=1 "$app"
