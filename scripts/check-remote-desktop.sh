#!/bin/bash
# 远程桌面（RFB）协议回归：TigerVNC 夹具覆盖编码、认证、键盘、指针、扩展剪贴板与 SSH -W 承载。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test/keys .test/rfb; chmod 700 .test .test/keys
[ -f .test/keys/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f .test/keys/id_ed25519
if [ -z "${FARPORT_TESTS:-}" ]; then swift build --build-system native --product workbench-tests; fi
tests="${FARPORT_TESTS:-$PWD/.build/debug/workbench-tests}"
docker image inspect farport-vnc-test:local >/dev/null 2>&1 || docker build --pull=false -f scripts/test-vnc.Dockerfile -t farport-vnc-test:local .
name=farport-vnc-fixture
if docker inspect "$name" >/dev/null 2>&1; then
  [ "$(docker inspect -f '{{index .Config.Labels "local.sshworkbench.fixture"}}' "$name")" = true ] || { echo "拒绝删除非本项目的同名容器" >&2; exit 1; }
  docker rm -f "$name" >/dev/null
fi
cleanup() { [ "${KEEP_FIXTURE:-0}" = 1 ] || docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$name" --label local.sshworkbench.fixture=true \
  -p 127.0.0.1:25901:5901 -p 127.0.0.1:25902:5902 -p 127.0.0.1:25903:5903 -p 127.0.0.1:22290:22 farport-vnc-test:local >/dev/null
for attempt in $(seq 1 20); do docker exec "$name" test -f /etc/ssh/ssh_host_ed25519_key.pub && break; sleep 0.5; done
docker exec "$name" sh -c 'mkdir -p /home/tester/.ssh && chmod 700 /home/tester/.ssh'
docker cp .test/keys/id_ed25519.pub "$name:/home/tester/.ssh/authorized_keys" >/dev/null
docker exec "$name" sh -c 'chmod 600 /home/tester/.ssh/authorized_keys; chown -R tester:tester /home/tester/.ssh'
printf '[127.0.0.1]:22290 %s\n' "$(docker exec "$name" cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1,2)" > .test/rfb/known_hosts
docker exec -u tester "$name" python3 -c '
import random
random.seed(1)
W, H = 1280, 800
out = bytearray(b"P6 %d %d 255\n" % (W, H))
for y in range(H):
    for x in range(W):
        if y < 200: px = (x * 255 // W, y * 255 // 200, 128)
        elif y < 400: px = (((x // 40 + y // 40) % 2) * 255, 64, ((x // 40) % 5) * 50)
        elif y < 600:
            v = random.randrange(256); px = (v, v * 3 % 256, v * 7 % 256)
        else: px = (200, 30, 30) if (x // 8 + y // 8) % 3 == 0 else (255, 255, 255)
        out += bytes(px)
open("/tmp/fixture.ppm", "wb").write(out)
'
docker exec -u tester -d "$name" Xvnc :1 -geometry 1280x800 -depth 24 -SecurityTypes None -rfbport 5901 -AlwaysShared
docker exec -u tester "$name" sh -c 'mkdir -p ~/.vnc && echo farport1 | vncpasswd -f > ~/.vnc/passwd && chmod 600 ~/.vnc/passwd'
docker exec -u tester -d "$name" Xvnc :2 -geometry 1024x768 -depth 24 -SecurityTypes VncAuth -PasswordFile /home/tester/.vnc/passwd -rfbport 5902 -AlwaysShared
sleep 1
docker exec -u tester -d "$name" sh -c 'DISPLAY=:1 feh --borderless --geometry 1280x800+0+0 /tmp/fixture.ppm'
docker exec -u tester -d "$name" sh -c 'DISPLAY=:2 xterm -geometry 140x50+0+0 -e sh -c "stty -echo; cat >> /tmp/keys.txt"'
for attempt in $(seq 1 40); do
  if docker exec -u tester "$name" sh -c 'DISPLAY=:2 xdotool search --class xterm >/dev/null 2>&1 && DISPLAY=:1 xdotool search --class feh >/dev/null 2>&1'; then break; fi
  sleep 0.25
done
docker exec -u tester "$name" sh -c 'DISPLAY=:2 xdotool search --class xterm | head -1 | xargs -I{} env DISPLAY=:2 xdotool windowfocus {}'
sleep 1
if [ "${1:-}" = "--bench" ]; then
  docker exec -u tester -d "$name" Xvnc :3 -geometry 2560x1440 -depth 24 -SecurityTypes None -rfbport 5903 -AlwaysShared
  docker exec -u tester "$name" sh -c 'head -c $((1280*1440*3)) /dev/urandom > /tmp/n1.raw; head -c $((1280*1440*3)) /dev/urandom > /tmp/n2.raw; for i in 1 2; do (printf "P6 1280 1440 255\n"; cat /tmp/n$i.raw) > /tmp/n$i.ppm; done'
  sleep 1
  docker exec -u tester -d "$name" sh -c 'DISPLAY=:3 xterm -geometry 180x90+0+0 -e sh -c "while :; do ls -lR /usr; done"'
  docker exec -u tester -d "$name" sh -c 'DISPLAY=:3 feh --borderless --geometry 1280x1440+1280+0 -D 0.1 /tmp/n1.ppm /tmp/n2.ppm'
  sleep 2
  RFB_BENCH=1 "$tests" --rfb-check "$(command -v docker)" "$name" 22290 "$PWD/.test/keys/id_ed25519" "$PWD/.test/rfb/known_hosts"
  exit 0
fi
"$tests" --rfb-check "$(command -v docker)" "$name" 22290 "$PWD/.test/keys/id_ed25519" "$PWD/.test/rfb/known_hosts"
if [ "${1:-}" = "--ui" ]; then
  app="${FARPORT_APP:-$PWD/.build/debug/SSHWorkbench}"
  if [ -z "${FARPORT_APP:-}" ]; then swift build --build-system native --product SSHWorkbench; fi
  for language in ${LANGS:-zh-Hans en}; do
    workspace=$(mktemp -d "$PWD/.test/rfb/ui.XXXXXX")
    cp .test/rfb/known_hosts "$workspace/known_hosts"
    cat > "$workspace/hosts.json" <<JSON
[{"id":"00000000-0000-4000-8000-0000000000b1","name":"VNC 夹具","address":"127.0.0.1","port":22290,"username":"tester","group":"测试","identityFile":"$PWD/.test/keys/id_ed25519","jumpHost":"","prefersTmux":false,"lastSession":"","color":"mint"}]
JSON
    docker exec -u tester "$name" sh -c ': > /tmp/keys.txt'
    FARPORT_LANGUAGE="$language" SWB_HOME="$workspace" SWB_QA_SCREEN=remote-desktop SWB_QA_DOCKER="$(command -v docker)" SWB_QA_VNC_CONTAINER="$name" \
      SWB_QA_HOLD="${SWB_QA_HOLD:-}" SWB_QA_VNC_PASSWORD=farport1 SWB_QA_OUTPUT="$workspace/screen.png" SWB_QA_EXIT=1 NSUnbufferedIO=YES "$app"
  done
fi
