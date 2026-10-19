#!/usr/bin/env python3
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


repository = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="farport-package-check-") as temporary:
    root = Path(temporary)
    for directory in ("scripts", "Resources", "bin", ".build/checkouts/SwiftTerm"):
        (root / directory).mkdir(parents=True)
    shutil.copy2(repository / "scripts/package.sh", root / "scripts/package.sh")
    shutil.copy2(repository / "Resources/Info.plist", root / "Resources/Info.plist")
    (root / "LICENSE").write_text("fixture")
    (root / ".build/checkouts/SwiftTerm/LICENSE").write_text("fixture")
    (root / ".build/AppIcon.icns").write_bytes(b"fixture")
    for architecture in ("arm64", "x86_64"):
        product = root / f".build/{architecture}-apple-macosx/release"
        product.mkdir(parents=True)
        for executable in ("SSHWorkbench", "workbench-askpass"):
            (product / executable).write_text("fixture")
        for resource in ("SwiftTerm_SwiftTerm", "SSHWorkbench_WorkbenchCore", "SSHWorkbench_OpenSSHBackend"):
            (product / f"{resource}.bundle").mkdir()
    shim = root / "bin/package-fixture"
    shim.write_text("""#!/bin/bash
case "$(basename "$0")" in
  nc) exit 1 ;;
  lipo)
    if [ "$1" = "-archs" ]; then
      case "$2" in *x86_64*) echo x86_64 ;; *) echo arm64 ;; esac
    fi ;;
  hdiutil) touch "${@: -1}" ;;
esac
exit 0
""")
    shim.chmod(0o755)
    for command in ("swift", "iconutil", "codesign", "lipo", "hdiutil", "nc"):
        (root / "bin" / command).symlink_to(shim.name)
    environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])

    def package(*arguments):
        result = subprocess.run(["/bin/bash", str(root / "scripts/package.sh"), *arguments],
                                env=environment, capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def info(application):
        with (application / "Contents/Info.plist").open("rb") as stream:
            return plistlib.load(stream)

    source = (root / "Resources/Info.plist").read_bytes()
    version = plistlib.loads(source)["CFBundleShortVersionString"]
    package("--arm64-only")
    normal = root / "dist/arm64/Farport.app"
    assert info(normal)["CFBundleIdentifier"] == "local.sshworkbench.mac"
    (normal / "normal-marker").write_text("keep")
    (root / "dist/Farport.app/alias-marker").write_text("keep")
    for arguments in (("--arm64-only", "--preview"), ("--preview", "--arm64-only")):
        package(*arguments)
        preview = root / "dist/preview/arm64/Farport Preview.app"
        metadata = info(preview)
        assert metadata["CFBundleIdentifier"] == "local.sshworkbench.preview"
        assert metadata["CFBundleName"] == "Farport Preview"
        assert metadata["CFBundleShortVersionString"] == version
        assert metadata["CFBundleVersion"] == plistlib.loads(source)["CFBundleVersion"]
        assert (normal / "normal-marker").read_text() == "keep"
        assert (root / "dist/Farport.app/alias-marker").read_text() == "keep"
        assert (root / "Resources/Info.plist").read_bytes() == source
        assert info(root / "dist/preview/Farport Preview.app") == metadata
        base = f"Farport-{version}-preview"
        with zipfile.ZipFile(root / f"dist/preview/{base}-arm64.zip") as archive:
            assert any(name.startswith("Farport Preview.app/") for name in archive.namelist())
            assert not any(name.startswith("Farport.app/") for name in archive.namelist())
        staging = root / ".build/dmg-staging-preview-arm64"
        assert (staging / "Farport Preview.app").is_dir()
        assert not (staging / "Farport.app").exists()
        for line in (root / f"dist/preview/{base}-SHA256SUMS").read_text().splitlines():
            digest, filename = line.split(None, 1)
            assert hashlib.sha256((root / "dist/preview" / filename).read_bytes()).hexdigest() == digest
    invalid = subprocess.run(["/bin/bash", str(root / "scripts/package.sh"), "--invalid"],
                             env=environment, capture_output=True, timeout=30)
    assert invalid.returncode != 0
print("PASS · 打包布局夹具：预览名称/身份/版本、ZIP和DMG布局、校验和、参数顺序、正式产物不被覆盖")
