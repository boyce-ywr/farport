#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test/app .test/keys
chmod 700 .test .test/app .test/keys
if [ ! -f .test/keys/id_ed25519 ]; then ssh-keygen -q -t ed25519 -N '' -f .test/keys/id_ed25519; fi
for suffix in a b; do
  name="swb-fixture-$suffix"
  if docker inspect "$name" >/dev/null 2>&1; then
    label=$(docker inspect -f '{{index .Config.Labels "local.sshworkbench.fixture"}}' "$name")
    [ "$label" = "true" ] || { echo "拒绝修改非本项目的同名容器" >&2; exit 1; }
    docker start "$name" >/dev/null
  else
    port=22281; [ "$suffix" = "a" ] || port=22282
    docker run -d --name "$name" --label local.sshworkbench.fixture=true --tmpfs /limited:rw,size=1048576,mode=1777 -p "127.0.0.1:$port:22" ssh-workbench-test:local >/dev/null
  fi
  for attempt in 1 2 3 4 5; do
    docker exec "$name" test -f /etc/ssh/ssh_host_ed25519_key.pub && break
    sleep 1
  done
  docker exec "$name" mkdir -p /home/tester/.ssh /home/tester/workspace/projects /home/tester/workspace/logs /home/tester/workspace/releases /home/tester/incoming
  docker cp .test/keys/id_ed25519.pub "$name:/home/tester/.ssh/authorized_keys" >/dev/null
  docker exec "$name" sh -c 'chmod 700 /home/tester/.ssh; chmod 600 /home/tester/.ssh/authorized_keys; chown -R tester:tester /home/tester'
  docker exec -i "$name" python3 - <<'PY'
from pathlib import Path
root = Path('/home/tester/workspace')
(root / 'README.md').write_text('# SSH Workbench 测试工作区\n\n这里是隔离 Linux 主机上的真实文件。\n支持中文、终端、tmux 与跨主机流式传输。\n', encoding='utf-8')
(root / 'app.config.json').write_text('{\n  "service": "atlas-api",\n  "environment": "development",\n  "port": 8080,\n  "workers": 4\n}\n')
(root / 'logs' / 'application.log').write_text('\n'.join(f'2026-10-13 12:00:{index % 60:02d} INFO request={index:04d} status=200 duration=12ms' for index in range(180))+'\n')
(root / 'projects' / '部署说明.md').write_text('部署前请检查配置，保留回滚版本。\n', encoding='utf-8')
with (root / 'releases' / 'sample.bin').open('wb') as output:
    output.write(bytes(range(256)) * 4096)
PY
  docker exec "$name" chown -R tester:tester /home/tester/workspace
  docker exec -u tester "$name" sh -c 'tmux has-session -t development 2>/dev/null || tmux new-session -d -s development -c /home/tester/workspace; tmux has-session -t monitoring 2>/dev/null || tmux new-session -d -s monitoring -c /home/tester/workspace/logs'
done
python3 - <<'PY'
import json, os, subprocess
from pathlib import Path
root = Path.cwd()
hosts = []
known = []
config = []
for suffix, name, port, color in [('a', 'Atlas · 开发环境', 22281, 'mint'), ('b', 'Orbit · 预发布', 22282, 'blue')]:
    public = subprocess.check_output(['docker', 'exec', f'swb-fixture-{suffix}', 'cat', '/etc/ssh/ssh_host_ed25519_key.pub'], text=True).split()
    known.append(f'[127.0.0.1]:{port} {public[0]} {public[1]}')
    internal = subprocess.check_output(['docker', 'inspect', '-f', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', f'swb-fixture-{suffix}'], text=True).strip()
    known.append(f'{internal} {public[0]} {public[1]}')
    config.append(f'Host swb-jump-{suffix}\n  HostName '+('127.0.0.1' if suffix=='a' else internal)+f'\n  Port '+(str(port) if suffix=='a' else '22')+f'\n  User tester\n  IdentityFile "{root / ".test/keys/id_ed25519"}"\n  UserKnownHostsFile "{root / ".test/app/known_hosts"}"\n  StrictHostKeyChecking yes\n  BatchMode yes\n')
    if suffix=='a':
        config.append(f'Host swb-target\n  HostName {internal}\n  Port 22\n  User tester\n  IdentityFile "{root / ".test/keys/id_ed25519"}"\n')
    hosts.append(dict(id='00000000-0000-4000-8000-00000000000'+('1' if suffix=='a' else '2'), name=name, address='127.0.0.1', port=port, username='tester', group='隔离测试 · Linux', identityFile=str(root / '.test/keys/id_ed25519'), jumpHost='', prefersTmux=True, lastSession='', color=color))
(root / '.test/app/hosts.json').write_text(json.dumps(hosts, ensure_ascii=False, indent=2))
(root / '.test/app/known_hosts').write_text('\n'.join(known)+'\n')
(root / '.test/ssh_config').write_text('\n'.join(config))
for filename in ['hosts.json', 'known_hosts']: os.chmod(root / '.test/app' / filename, 0o600)
print('隔离 SSH 环境就绪：127.0.0.1:22281 / :22282')
PY
