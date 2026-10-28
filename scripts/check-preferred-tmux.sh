#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
test -f .test/app/hosts.json || { echo "请先运行 scripts/test-environment.sh 准备隔离 SSH 主机。" >&2; exit 1; }
test "$(docker inspect -f '{{index .Config.Labels "local.sshworkbench.fixture"}}' swb-fixture-a)" = true
test "$(docker port swb-fixture-a 22/tcp)" = "127.0.0.1:22281"
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/preferred-tmux-$language.XXXXXX")
  cp .test/app/hosts.json .test/app/known_hosts "$workspace/"
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=preferred-tmux \
    SWB_QA_OUTPUT="$workspace/sessions.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES \
    python3 -c 'import subprocess,sys; subprocess.run([sys.argv[1]],check=True,timeout=180)' "$app"
done
