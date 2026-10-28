#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/prepare-swiftterm.sh
swift build --build-system native
.build/debug/workbench-tests
if [ "${1:-}" = "--integration" ] || [ "${1:-}" = "--stress" ]; then
  docker build --pull=false -f scripts/test-server.Dockerfile -t ssh-workbench-test:local .
  bash scripts/test-environment.sh
  .build/debug/workbench-check .test/app
fi
if [ "${1:-}" = "--stress" ]; then
  mkdir -p .test/stress-app
  cp .test/app/hosts.json .test/app/known_hosts .test/stress-app/
  /usr/bin/time -l .build/debug/workbench-check .test/stress-app --stress
fi
