#!/bin/bash
# herdr 窗格前台为 docker exec 时的附件：识别容器、上传到容器、插入容器内路径。
#   --loopback  加入本机回环 SSH（127.0.0.1:22，模拟远端 Mac）
# 需要本机已安装 herdr 和测试镜像 ssh-workbench-test:local；只创建带测试标签的容器与随机 fp-att-* herdr 会话。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
image=$(docker image inspect ssh-workbench-test:local --format '{{.Id}}')
container=""; mounted=""
mount_dir=$(mktemp -d "$PWD/.test/herdr-mount.XXXXXX"); printf probe > "$mount_dir/probe.txt"
cleanup() {
  for item in "$container" "$mounted"; do
    if [ -n "$item" ] && [ "$(docker inspect -f "{{index .Config.Labels \"local.sshworkbench.docker-attachments\"}}" "$item" 2>/dev/null)" = true ]; then docker rm -f "$item" >/dev/null; fi
  done
  rm -rf "$mount_dir"
}
trap cleanup EXIT
container=$(docker run -d --pull=never --network none --label local.sshworkbench.docker-attachments=true --entrypoint /bin/sleep "$image" 900)
mounted=$(docker run -d --pull=never --network none --label local.sshworkbench.docker-attachments=true -v "$mount_dir:/app" --entrypoint /bin/sleep "$image" 900)
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/herdr-attachments.XXXXXX")
  if [ "${1:-}" = "--loopback" ]; then
    cp .test/remote-clipboard-20261029/loopback_known_hosts "$workspace/known_hosts"
    printf '[{"id":"00000000-0000-4000-8000-0000000000ad","name":"loopback-mac","address":"127.0.0.1","port":22,"username":"%s","group":"测试","identityFile":"","jumpHost":"","prefersTmux":false,"lastSession":"","color":"mint"}]' "$(id -un)" > "$workspace/hosts.json"
  fi
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=herdr-attachments SWB_QA_DOCKER="$(command -v docker)" \
    SWB_QA_CONTAINER_ID="$container" SWB_QA_MOUNT_CONTAINER_ID="$mounted" SWB_QA_MOUNT_DIR="$mount_dir" SWB_QA_OUTPUT="$workspace/out.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES "$app"
done
