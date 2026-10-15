#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
test -f .test/app/hosts.json || { echo "请先准备隔离 SSH 测试主机。" >&2; exit 1; }
mkdir -p .test/ui-regression
for language in zh-Hans en; do
  for screen in navigation-preview xml-preview java-preview python-preview media-preview; do
    workspace=$(mktemp -d "$PWD/.test/preview-$language-$screen.XXXXXX")
    cp .test/app/hosts.json .test/app/known_hosts "$workspace/"
    FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN="$screen" \
    SWB_QA_OUTPUT="$PWD/.test/ui-regression/$screen-$language.png" SWB_QA_APPEARANCE=dark SWB_QA_EXIT=1 "$app"
  done
done
workspace=$(mktemp -d "$PWD/.test/language-settings.XXXXXX")
FARPORT_LANGUAGE=en SWB_HOME="$workspace" SWB_QA_SCREEN=language-settings \
SWB_QA_OUTPUT="$PWD/.test/ui-regression/language-settings.png" SWB_QA_EXIT=1 "$app"
