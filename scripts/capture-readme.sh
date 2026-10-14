#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -f .test/app/hosts.json || { echo "先运行 scripts/test-environment.sh 准备隔离 SSH 测试容器。" >&2; exit 1; }
command -v jq >/dev/null
swift build --build-system native --product SSHWorkbench
workspace=$(mktemp -d "$PWD/.test/readme.XXXXXX")
jq '[.[] | select(.address == "127.0.0.1" and (.port == 22281 or .port == 22282))] | sort_by(.port) | .[0].name = "Atlas · 开发机" | .[0].group = "演示主机" | .[0].color = "blue" | .[1].name = "Orbit · 测试机" | .[1].group = "演示主机" | .[1].color = "mint"' .test/app/hosts.json > "$workspace/hosts.json"
cp .test/app/known_hosts "$workspace/known_hosts"
chmod 700 "$workspace"
chmod 600 "$workspace/hosts.json" "$workspace/known_hosts"
mkdir -p docs/images
for scene in terminal tmux markdown html transfers; do
  SWB_HOME="$workspace" SWB_QA_SCREEN="readme-$scene" SWB_QA_OUTPUT="$PWD/docs/images/$scene.png" \
  SWB_QA_EXIT=1 .build/debug/SSHWorkbench
done
printf '\n截图已写入 docs/images；提交前逐张检查并移除私人信息。\n'
