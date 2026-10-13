#!/bin/bash
set -euo pipefail
for container in swb-fixture-a swb-fixture-b; do
  if docker inspect "$container" >/dev/null 2>&1; then
    label=$(docker inspect -f '{{index .Config.Labels "local.sshworkbench.fixture"}}' "$container")
    [ "$label" = "true" ] || { echo "拒绝操作非本项目测试容器：$container" >&2; exit 1; }
    docker stop "$container"
  fi
done
