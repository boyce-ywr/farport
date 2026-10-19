#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-stability}"
case "$mode" in stability|manual|recovery) ;; *) echo "用法：$0 stability|manual|recovery" >&2; exit 2;; esac
app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
image=$(docker image inspect ssh-workbench-test:local --format '{{.Id}}')
mkdir -p .test
workspace=$(mktemp -d "$PWD/.test/connection-$mode.XXXXXX")
token=$(basename "$workspace")
container=""
cleanup() {
  if [ -n "$container" ]; then
    label=$(docker inspect -f '{{index .Config.Labels "local.sshworkbench.recovery"}}' "$container" 2>/dev/null || true)
    if [ "$label" = "$token" ]; then docker rm -f "$container" >/dev/null; fi
  fi
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$workspace/id_ed25519"
container=$(docker run -d --pull=never --name "swb-$token" --label "local.sshworkbench.recovery=$token" --cpus 1 --memory 256m -p 127.0.0.1::22 "$image")
for attempt in $(seq 1 30); do docker exec "$container" test -f /etc/ssh/ssh_host_ed25519_key.pub && break; sleep 1; done
docker exec "$container" mkdir -p /home/tester/.ssh
docker cp "$workspace/id_ed25519.pub" "$container:/home/tester/.ssh/authorized_keys" >/dev/null
docker exec "$container" sh -c 'chmod 700 /home/tester/.ssh; chmod 600 /home/tester/.ssh/authorized_keys; chown -R tester:tester /home/tester/.ssh'
python3 - "$workspace" "$container" <<'PY'
import json, os, subprocess, sys, uuid
from pathlib import Path
root=Path(sys.argv[1]); container=sys.argv[2]
port=int(subprocess.check_output(['docker','port',container,'22/tcp'],text=True).strip().rsplit(':',1)[1])
key=subprocess.check_output(['docker','exec',container,'cat','/etc/ssh/ssh_host_ed25519_key.pub'],text=True).split()
host=dict(id=str(uuid.uuid4()),name='Recovery Fixture',address='127.0.0.1',port=port,username='tester',group='QA',identityFile=str(root/'id_ed25519'),jumpHost='',prefersTmux=False,lastSession='',color='mint')
(root/'hosts.json').write_text(json.dumps([host]))
(root/'known_hosts').write_text(f'[127.0.0.1]:{port} {key[0]} {key[1]}\n')
for name in ('hosts.json','known_hosts'): os.chmod(root/name,0o600)
PY
SWB_HOME="$workspace" SWB_QA_SCREEN=connection-stability SWB_QA_RECOVERY_MODE="$mode" \
  SWB_QA_CONTAINER_ID="$container" SWB_QA_DOCKER="$(command -v docker)" \
  SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES "$app"
