#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 4 ]; then
  echo "用法：bash scripts/check-large-directory.sh 地址 端口 用户名 目录（仅只读验证）" >&2
  exit 2
fi
swift build --build-system native --product SSHWorkbench
swift build --build-system native --product workbench-tests
.build/debug/workbench-tests --device-files-check "$1" "$2" "$3" "$4"
workspace=$(mktemp -d "$PWD/.test/large-directory.XXXXXX")
cp .test/device-check/hosts.json .test/device-check/known_hosts "$workspace/"
SWB_HOME="$workspace" SWB_QA_SCREEN=large-directory SWB_QA_DIRECTORY="$4" \
SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES \
  python3 - <<'PY'
import subprocess

process = subprocess.Popen([".build/debug/SSHWorkbench"])
try:
    result = process.wait(timeout=120)
except subprocess.TimeoutExpired:
    process.kill()
    process.wait()
    raise SystemExit("FAIL · 大目录界面验证超过 120 秒，已停止测试进程")
raise SystemExit(result)
PY
