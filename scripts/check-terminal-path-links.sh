#!/bin/bash
# 终端路径 Cmd+点击端到端检查。
#   --ssh     加入隔离 SSH 测试主机（127.0.0.1:22281，需先运行 scripts/test-environment.sh）
#   --docker  加入本机回环 SSH（127.0.0.1:22，模拟远端 Mac），并在本机与回环 tmux 中验证 docker exec 容器路径换算
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test/ui-regression
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
ssh=false; docker=""
for argument in "$@"; do
  case "$argument" in
    --ssh) ssh=true ;;
    --docker) docker=$(command -v docker) ;;
    *) echo "用法：$0 [--ssh] [--docker]" >&2; exit 2 ;;
  esac
done
for language in zh-Hans en; do
  workspace=$(mktemp -d "$PWD/.test/terminal-path-links.XXXXXX")
  python3 - "$workspace" "$ssh" "$docker" "$(id -un)" <<'PY'
import json, shutil, sys
from pathlib import Path
workspace, ssh, docker, user = Path(sys.argv[1]), sys.argv[2] == "true", sys.argv[3], sys.argv[4]
hosts, known = [], ""
if ssh:
    hosts += json.loads(Path(".test/app/hosts.json").read_text()); known += Path(".test/app/known_hosts").read_text()
if docker:
    hosts.append({"id": "00000000-0000-4000-8000-0000000000ab", "name": "loopback-mac", "address": "127.0.0.1", "port": 22, "username": user, "group": "测试",
                  "identityFile": "", "jumpHost": "", "prefersTmux": True, "lastSession": "", "color": "mint"})
    known += Path(".test/remote-clipboard-20261029/loopback_known_hosts").read_text()
if hosts:
    (workspace / "hosts.json").write_text(json.dumps(hosts, ensure_ascii=False)); (workspace / "known_hosts").write_text(known)
PY
  FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=terminal-path-links SWB_QA_OUTPUT="$PWD/.test/ui-regression/terminal-path-links-$language.png" \
    SWB_QA_LINK_DOCKER="$docker" SWB_QA_APPEARANCE=dark SWB_QA_EXIT=1 NSUnbufferedIO=YES "$app"
done
