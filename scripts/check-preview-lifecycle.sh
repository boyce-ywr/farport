#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-debug}"
swift build --build-system native -c "$configuration"
tests="$PWD/.build/$configuration/workbench-tests"
"$tests" --preview-lifecycle-check
if [ "${1:-}" = "--ssh" ]; then "$tests" --preview-lifecycle-ssh "$PWD/.test/app"; fi
"$tests" --preview-timeout-check
if [ "${1:-}" = "--ssh" ]; then
  workspace=$(mktemp -d "$PWD/.test/media-lifecycle.XXXXXX")
  cp .test/app/hosts.json .test/app/known_hosts "$workspace/"
  SWB_HOME="$workspace" SWB_QA_SCREEN=media-preview SWB_QA_MEDIA_LIFECYCLE=1 \
  SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 \
    "${FARPORT_APP:-$PWD/.build/$configuration/SSHWorkbench}"
fi
