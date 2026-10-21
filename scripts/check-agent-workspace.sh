#!/bin/bash
set -euo pipefail
case "${1:-}" in ""|--models) ;; *) echo "用法：$0 [--models]" >&2; exit 2;; esac
cd "$(dirname "$0")/.."
mkdir -p .test
swift build --build-system native
.build/debug/workbench-tests --agent-session-check
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/agent-workspace.XXXXXX")
  screen=agent-workspace
  if [ "${1:-}" = --models ]; then screen=agent-workspace-models; fi
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN="$screen" SWB_QA_OUTPUT="$workspace/panel.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES \
    python3 -c 'import subprocess,sys; subprocess.run([sys.argv[1]], check=True, timeout=180)' "${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
done
