#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product workbench-tests
.build/debug/workbench-tests --file-move-check
if [ "${1:-}" = "--ssh" ]; then
  test -f .test/app/hosts.json || { echo "请先准备隔离 SSH 测试主机。" >&2; exit 1; }
  .build/debug/workbench-tests --file-move-ssh .test/app
fi
if [ "${1:-}" = "--ui" ]; then
  swift build --build-system native --product SSHWorkbench
  mkdir -p .test
  for language in zh-Hans en; do
    workspace=$(mktemp -d "$PWD/.test/file-moves-$language.XXXXXX")
    FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=file-moves \
      SWB_QA_OUTPUT="$workspace/cut-selection.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES .build/debug/SSHWorkbench
  done
fi
