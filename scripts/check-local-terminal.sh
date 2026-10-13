#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
mkdir -p .test/ui-regression
workspace=$(mktemp -d "$PWD/.test/local-terminal.XXXXXX")
if [ "${1:-}" = "--mixed" ]; then
  test -f .test/app/hosts.json || { echo "混合分屏检查需要先运行 test-environment.sh" >&2; exit 1; }
  cp .test/app/hosts.json .test/app/known_hosts "$workspace/"
  screen=local-mixed
else
  screen=local-terminal
fi
for appearance in light dark; do
  output="$PWD/.test/ui-regression/$screen-$appearance.png"
  rm -f "$output" "$output.json"
  SWB_HOME="$workspace" SWB_QA_OUTPUT="$output" SWB_QA_SCREEN="$screen" SWB_QA_APPEARANCE="$appearance" SWB_QA_EXIT=1 "$app"
  test -s "$output"
  test -s "$output.json"
done
