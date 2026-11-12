#!/bin/bash
# 真实 App 验证 Zellij/herdr 会话支持：会话页检测、终端附着、关闭只分离、herdr 终端内新建、结束删除。
#   --loopback  加入本机回环 SSH（127.0.0.1:22，模拟远端 Mac）；需要已存在 .test/remote-clipboard-20261029/loopback_known_hosts
# 需要本机已安装 Zellij（≥0.44）与 herdr（≥0.9）；只创建随机 farport-test-ui-* 会话并在结束时清理。
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
.build/debug/workbench-tests --multiplexer-live
loopback=false
[ "${1:-}" = "--loopback" ] && loopback=true
mkdir -p .test/ui-regression
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/multiplexers-$language.XXXXXX")
  if $loopback; then
    cp .test/remote-clipboard-20261029/loopback_known_hosts "$workspace/known_hosts"
    printf '[{"id":"00000000-0000-4000-8000-0000000000ac","name":"loopback-mac","address":"127.0.0.1","port":22,"username":"%s","group":"测试","identityFile":"","jumpHost":"","prefersTmux":false,"lastSession":"","color":"mint"}]' "$(id -un)" > "$workspace/hosts.json"
  fi
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=multiplexer-sessions SWB_QA_OUTPUT="$PWD/.test/ui-regression/multiplexers-$language.png" \
    SWB_QA_EXIT=1 NSUnbufferedIO=YES "$app"
done
