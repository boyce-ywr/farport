#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
test -f .test/app/hosts.json || { echo "请先准备隔离 SSH 测试主机。" >&2; exit 1; }
mkdir -p .test/ui-regression
workspace=$(mktemp -d "$PWD/.test/file-switching.XXXXXX")
cp .test/app/hosts.json .test/app/known_hosts "$workspace/"
SWB_HOME="$workspace" SWB_QA_OUTPUT="$PWD/.test/ui-regression/file-switching.png" \
SWB_QA_SCREEN=file-switching SWB_QA_APPEARANCE=dark SWB_QA_EXIT=1 "$app"
