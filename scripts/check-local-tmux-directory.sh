#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product workbench-tests
tests="$PWD/.build/debug/workbench-tests"
mkdir -p .test
workspace=$(mktemp -d "$PWD/.test/local-tmux-directory.XXXXXX")
for directory in / "$workspace"; do
  echo "从 $directory 启动本机 tmux 目录回归"
  (cd "$directory" && "$tests" --local-tmux-directory-check)
done
