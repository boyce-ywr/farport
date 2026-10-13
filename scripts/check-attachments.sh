#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native
.build/debug/workbench-attachment-check .test/app
mkdir -p .test/ui-regression
SWB_HOME="$PWD/.test/app" SWB_QA_OUTPUT="$PWD/.test/ui-regression/attachments.png" \
SWB_QA_SCREEN=attachment-check SWB_QA_EXIT=1 .build/debug/SSHWorkbench
