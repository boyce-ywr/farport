#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
mkdir -p .test/ui-regression
workspace=$(mktemp -d "$PWD/.test/terminal-zoom.XXXXXX")
SWB_HOME="$workspace" SWB_QA_OUTPUT="$PWD/.test/ui-regression/terminal-zoom.png" \
SWB_QA_SCREEN=terminal-zoom SWB_QA_EXIT=1 "$app"
