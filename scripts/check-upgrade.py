#!/usr/bin/env python3
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


if len(sys.argv) != 3:
    raise SystemExit("用法：python3 scripts/check-upgrade.py 旧正式版ZIP 新正式版.app")
repository = Path(__file__).resolve().parent.parent
workspace = Path(tempfile.mkdtemp(prefix="upgrade-", dir=repository / ".test"))
installed = workspace / "Applications"
installed.mkdir()
subprocess.run(["/usr/bin/ditto", "-x", "-k", str(Path(sys.argv[1]).resolve()), str(installed)], check=True)
application = installed / "Farport.app"
with (application / "Contents/Info.plist").open("rb") as stream:
    old_info = plistlib.load(stream)
assert old_info["CFBundleIdentifier"] == "local.sshworkbench.mac"
assert old_info["CFBundleShortVersionString"] == "0.1.9"
data = workspace / "Library/Application Support/SSH Workbench"
baseline = data / "upgrade-baseline"
baseline.mkdir(parents=True)
host_id = str(uuid.uuid4())
host = dict(id=host_id, name="旧主机测试", address="legacy.invalid", port=2222,
            username="fixture", group="旧分组", identityFile="/fixture/key", jumpHost="jump.invalid",
            prefersTmux=True, lastSession="$9", color="mint")
jobs = []
for index, status in enumerate(("running", "queued", "completed")):
    jobs.append(dict(id=str(uuid.uuid4()), source=dict(hostID=host_id, path="/remote/source.bin"),
                     destination=dict(path="/local/target.bin"), status=status, totalBytes=4096,
                     completedBytes=4096 if status == "completed" else 2048,
                     entries=[dict(relativePath="中文.bin", attributes=dict(size=4096, permissions=33188,
                                  modified=1700000000, uid=501, gid=20), finished=status == "completed")],
                     message="legacy fixture", created=1000 + index, overwrite=False))
fixtures = {"hosts.json": json.dumps([host], ensure_ascii=False).encode(),
            "transfers.json": json.dumps(jobs, ensure_ascii=False).encode()}
host_key = workspace / "fixture-host-key"
subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(host_key)], check=True)
public_key = host_key.with_suffix(".pub").read_text().split()
fixtures["known_hosts"] = f"[legacy.invalid]:2222 {public_key[0]} {public_key[1]}\n".encode()
for name, content in fixtures.items():
    for directory in (data, baseline):
        (directory / name).write_bytes(content)
        (directory / name).chmod(0o600)
application.rename(installed / "Farport-previous.app")
subprocess.run(["/usr/bin/ditto", str(Path(sys.argv[2]).resolve()), str(application)], check=True)
with (application / "Contents/Info.plist").open("rb") as stream:
    new_info = plistlib.load(stream)
assert new_info["CFBundleIdentifier"] == old_info["CFBundleIdentifier"]
assert new_info["CFBundleName"] == "Farport"
for run in range(2):
    output = workspace / f"run-{run}.log"
    error = workspace / f"run-{run}.error.log"
    arguments = ["/usr/bin/open", "-n", "-o", str(output), "--stderr", str(error)]
    for key, value in {"SWB_HOME": str(data), "SWB_QA_SCREEN": "upgrade-compatibility",
                       "SWB_QA_OUTPUT": str(workspace / "screen.png"), "SWB_QA_EXIT": "1",
                       "FARPORT_LANGUAGE": "zh-Hans", "NSUnbufferedIO": "YES"}.items():
        arguments.extend(("--env", key + "=" + value))
    arguments.extend((str(application), "--args", "-fontSize", "17", "-fontName", "Menlo",
                      "-appearance", "dark", "-useTmuxContextMenu", "YES"))
    subprocess.run(arguments, check=True, timeout=10)
    deadline = time.monotonic() + 40
    while True:
        message = output.read_text(errors="replace") if output.exists() else ""
        failure = error.read_text(errors="replace") if error.exists() else ""
        if "FAIL ·" in failure:
            raise SystemExit(f"升级验收失败，证据：{workspace}")
        if "PASS · 正式身份读取旧版" in message:
            break
        if time.monotonic() > deadline:
            raise SystemExit(f"升级验收等待超时，证据：{workspace}")
        time.sleep(0.2)
    print(f"PASS · 旧版替换后第{run + 1}次启动：配置、偏好键、指纹、断点保存重读一致", flush=True)
    time.sleep(1)
assert (data / "known_hosts").read_bytes() == fixtures["known_hosts"]
print(f"PASS · {old_info['CFBundleShortVersionString']} → {new_info['CFBundleShortVersionString']} 隔离升级与重启；未读取真实用户主机或钥匙串")
