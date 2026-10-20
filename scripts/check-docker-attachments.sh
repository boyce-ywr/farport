#!/bin/bash
set -euo pipefail
case "${1:-}" in ""|--models|--ui) ;; *) echo "用法：$0 [--models|--ui]" >&2; exit 2;; esac
cd "$(dirname "$0")/.."
mkdir -p .test
swift build --build-system native --product workbench-tests
image=$(docker image inspect ssh-workbench-test:local --format '{{.Id}}')
first=""; second=""
cleanup() {
  for container in "$first" "$second"; do
    if [ -n "$container" ] && [ "$(docker inspect -f '{{index .Config.Labels "local.sshworkbench.docker-attachments"}}' "$container" 2>/dev/null)" = true ]; then docker rm -f "$container" >/dev/null; fi
  done
}
trap cleanup EXIT
first=$(docker run -d --pull=never --network none --label local.sshworkbench.docker-attachments=true --entrypoint /bin/sleep "$image" 600)
second=$(docker run -d --pull=never --network none --label local.sshworkbench.docker-attachments=true --entrypoint /bin/sleep "$image" 600)
.build/debug/workbench-tests --docker-attachments-check "$(command -v docker)" "$first" "$second"
if [ "${1:-}" = "--ui" ] || [ "${1:-}" = "--models" ]; then
  app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
  if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
  screen=docker-attachments
  if [ "${1:-}" = "--models" ]; then screen=docker-attachment-models; fi
  for language in zh-Hans en; do
    workspace=$(mktemp -d "$PWD/.test/docker-attachment-ui.XXXXXX")
    FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN="$screen" SWB_QA_DOCKER="$(command -v docker)" \
      SWB_QA_CONTAINER_ID="$first" SWB_QA_OUTPUT="$workspace/picker.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES \
      python3 -c 'import subprocess,sys; subprocess.run([sys.argv[1]], check=True, timeout=180)' "$app"
  done
fi
