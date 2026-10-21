#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/split-directory.XXXXXX")
  if [ "${1:-}" = "--ssh" ]; then cp .test/app/hosts.json .test/app/known_hosts "$workspace/"; fi
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=split-directory SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES \
    python3 -c 'import subprocess,sys; subprocess.run([sys.argv[1]],check=True,timeout=150)' "$app"
done
