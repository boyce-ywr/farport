#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product workbench-tests
.build/debug/workbench-tests --html-resources-check
swift build --build-system native --product SSHWorkbench
mkdir -p .test
targets=(local)
if [ "${1:-}" = "--ssh" ]; then
  test -f .test/app/hosts.json || { echo "请先准备隔离 SSH 测试主机。" >&2; exit 1; }
  targets+=(ssh)
fi
for target in "${targets[@]}"; do
  workspace=$(mktemp -d "$PWD/.test/html-resources-$target.XXXXXX")
  if [ "$target" = ssh ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
  SWB_HOME="$workspace" SWB_QA_SCREEN=html-resources SWB_QA_REQUIRE_SSH="$([ "$target" = ssh ] && echo 1 || echo 0)" \
    SWB_QA_OUTPUT="$workspace/html-resources.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES .build/debug/SSHWorkbench
done
