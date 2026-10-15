#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native; fi
test -f .test/app/hosts.json || { echo "请先准备隔离 SSH 测试主机。" >&2; exit 1; }
mkdir -p .test/ui-regression
for spec in 'host-monitor:overview:zh-Hans' 'local-monitor:processes:zh-Hans' 'local-monitor:network:en' 'host-monitor:system:en' 'terminal-preferences:overview:zh-Hans'; do
  IFS=: read -r screen section language <<< "$spec"
  workspace=$(mktemp -d "$PWD/.test/monitor.XXXXXX")
  cp .test/app/hosts.json .test/app/known_hosts "$workspace/"
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN="$screen" SWB_QA_MONITOR_SECTION="$section" \
  SWB_QA_OUTPUT="$PWD/.test/ui-regression/${screen}-${section}-${language}.png" SWB_QA_APPEARANCE=dark SWB_QA_EXIT=1 "$app"
done
