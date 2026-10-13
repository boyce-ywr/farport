#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${FARPORT_APP:-$PWD/dist/Farport.app/Contents/MacOS/SSHWorkbench}"
if [ ! -x "$app" ]; then bash scripts/package.sh --debug; fi
mkdir -p docs/screenshots
workspace=$(mktemp -d "$PWD/.test/qa-run.XXXXXX")
cp .test/app/hosts.json .test/app/known_hosts "$workspace/"
if [ -f .test/app/transfers.json ]; then cp .test/app/transfers.json "$workspace/"; fi
for appearance in light dark; do
  for screen in terminal tmux files transfers; do
    output="$PWD/docs/screenshots/$screen-$appearance.png"
    rm -f "$output" "$output.json"
    SWB_HOME="$workspace" SWB_QA_OUTPUT="$output" SWB_QA_SCREEN="$screen" SWB_QA_APPEARANCE="$appearance" SWB_QA_EXIT=1 "$app"
    test -s "$output"
    test -s "$output.json"
    printf '已捕获真实应用窗口：%s\n' "$output"
  done
done
for screen in split tmux-terminal; do
  output="$PWD/docs/screenshots/$screen-dark.png"
  rm -f "$output" "$output.json"
  SWB_HOME="$workspace" SWB_QA_OUTPUT="$output" SWB_QA_SCREEN="$screen" SWB_QA_APPEARANCE=dark SWB_QA_EXIT=1 "$app"
  test -s "$output"
done
output="$PWD/docs/screenshots/files-compact.png"
rm -f "$output" "$output.json"
SWB_HOME="$workspace" SWB_QA_OUTPUT="$output" SWB_QA_SCREEN=files SWB_QA_APPEARANCE=light SWB_QA_WIDTH=980 SWB_QA_HEIGHT=640 SWB_QA_EXIT=1 "$app"
test -s "$output"
