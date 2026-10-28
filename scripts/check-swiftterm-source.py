#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import tempfile

repository = Path(__file__).resolve().parent.parent
source = repository / '.build/swiftterm-source'
prepared = repository / '.build/swiftterm'
revision = re.search(r'^revision=([0-9a-f]{40})$', (repository / 'scripts/prepare-swiftterm.sh').read_text(), re.MULTILINE).group(1)
assert (prepared / 'SOURCE_REVISION').read_text().strip() == revision
assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == revision
assert not subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=all'])
entries = subprocess.check_output(['git', '-C', str(source), 'ls-tree', '-r', '-z', revision, '--', 'Sources/SwiftTerm', 'LICENSE']).split(b'\0')
expected = set()
for entry in filter(None, entries):
    metadata, encoded = entry.split(b'\t', 1)
    mode, kind, digest = metadata.decode().split()
    relative = encoded.decode()
    path = prepared / relative
    assert kind == 'blob' and mode in ('100644', '100755'), relative
    assert path.is_file() and not path.is_symlink(), relative
    actual = subprocess.check_output(['git', 'hash-object', str(path)], text=True).strip()
    assert actual == digest, relative
    expected.add(relative)
generated = 'Sources/SwiftTerm/SwiftTermBuildInfo.swift'
actual = {str(path.relative_to(prepared)) for path in (prepared / 'Sources/SwiftTerm').rglob('*') if path.is_file()}
assert actual == (expected - {'LICENSE'}) | {generated}
assert (prepared / 'Package.swift').read_bytes() == (repository / 'BuildSupport/SwiftTerm/Package.swift').read_bytes()
with tempfile.TemporaryDirectory(prefix='farport-build-info-') as temporary:
    output = Path(temporary) / 'SwiftTermBuildInfo.swift'
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    architecture = subprocess.check_output(['uname', '-m'], text=True).strip()
    subprocess.run(['env', '-u', 'SWIFTTERM_BUILD_BRANCH', '-u', 'SWIFTTERM_BUILD_TAG', '-u', 'SWIFTTERM_BUILD_COMMIT', '-u', 'SWIFTTERM_BUILD_DIRTY',
                    'swift', '-frontend', '-interpret', '-parse-as-library', '-sdk', sdk, '-target', architecture + '-apple-macosx14.0',
                    str(source / 'Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift'), '--', str(source), str(output)], check=True, timeout=60)
    assert output.read_bytes() == (prepared / generated).read_bytes()
print('PASS · SwiftTerm', len(expected), '个原始文件、精确Git blob、构建描述及原生成器输出一致')
