#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product workbench-attachment-check
test -f .test/keys/id_ed25519.pub || { echo '请先准备隔离测试密钥'; exit 1; }
container=swb-tmux-path
if ! docker inspect "$container" >/dev/null 2>&1; then
  docker run -d --name "$container" --label local.sshworkbench.fixture=true -p 127.0.0.1:22283:22 ssh-workbench-test:local sh -c 'mkdir -p /opt/homebrew/bin; mv /usr/bin/tmux /opt/homebrew/bin/tmux; ssh-keygen -A; exec /usr/sbin/sshd -D -e' >/dev/null
else
  [ "$(docker inspect -f '{{index .Config.Labels "local.sshworkbench.fixture"}}' "$container")" = true ] || exit 1
  docker start "$container" >/dev/null
fi
trap 'docker stop "$container" >/dev/null 2>&1 || true' EXIT
docker exec "$container" mkdir -p /home/tester/.ssh
docker cp .test/keys/id_ed25519.pub "$container:/home/tester/.ssh/authorized_keys" >/dev/null
docker exec "$container" sh -c 'chmod 700 /home/tester/.ssh; chmod 600 /home/tester/.ssh/authorized_keys; chown -R tester:tester /home/tester/.ssh'
python3 - <<'PY'
import json,os,subprocess,time
from pathlib import Path
root=Path.cwd()
folder=root/'.test/tmux-path-app'
folder.mkdir(exist_ok=True,mode=0o700)
host=json.loads((root/'.test/app/hosts.json').read_text())[0]
host.update(name='隔离 Homebrew tmux PATH',port=22283)
for attempt in range(10):
    result=subprocess.run(['docker','exec','swb-tmux-path','cat','/etc/ssh/ssh_host_ed25519_key.pub'],capture_output=True,text=True)
    if result.returncode==0: break
    time.sleep(.2)
key=result.stdout.split()
(folder/'hosts.json').write_text(json.dumps([host],ensure_ascii=False))
(folder/'known_hosts').write_text('[127.0.0.1]:22283 '+key[0]+' '+key[1]+'\n')
for name in ['hosts.json','known_hosts']: os.chmod(folder/name,0o600)
PY
.build/debug/workbench-attachment-check .test/tmux-path-app --tmux-path
