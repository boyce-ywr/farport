#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native; fi
workspace=$(mktemp -d "$PWD/.test/terminal-graphics.XXXXXX")
if [ "${1:-}" = "--ssh" ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
SWB_HOME="$workspace" SWB_QA_SCREEN=terminal-graphics SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 "$app"
printf '\n图像验收截图：%s\n' "$workspace"
if [ -z "${SWB_QA_CODEX_HOME:-}" ] || [ -z "${SWB_QA_REMOTE_CODEX_HOME:-}" ]; then
  printf '本次只验证已配置的测试范围；真实 Codex 需设置 SWB_QA_CODEX/HOME 与 SWB_QA_REMOTE_CODEX/HOME。\n'
fi
