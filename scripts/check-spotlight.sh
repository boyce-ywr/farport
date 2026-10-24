#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product SSHWorkbench
test -f .test/app/hosts.json || { echo "请先准备隔离 SSH 测试主机。" >&2; exit 1; }
mkdir -p .test/ui-regression
SWB_HOME="$PWD/.test/app" \
SWB_QA_OUTPUT="$PWD/.test/ui-regression/spotlight.png" \
SWB_QA_SCREEN=files SWB_QA_SPOTLIGHT=1 SWB_QA_EXIT=1 \
  .build/debug/SSHWorkbench
