#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product SSHWorkbench
mkdir -p .test/ui-regression
SWB_HOME="$PWD/.test/app" SWB_QA_OUTPUT="$PWD/.test/ui-regression/tabs.png" \
SWB_QA_SCREEN=terminal SWB_QA_INTERACTIONS=1 SWB_QA_EXIT=1 .build/debug/SSHWorkbench
