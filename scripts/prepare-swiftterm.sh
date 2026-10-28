#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=5d14406844143538cd8f8851d2d8a67c1fe443e5
source="$PWD/.build/swiftterm-source"
destination="$PWD/.build/swiftterm"
mkdir -p .build
if [ ! -d "$source/.git" ]; then
  if git -C .build/checkouts/SwiftTerm cat-file -e "$revision^{commit}" 2>/dev/null; then
    git clone --no-checkout .build/checkouts/SwiftTerm "$source"
  else
    git -c http.proxy=http://127.0.0.1:7897 clone --no-checkout https://github.com/migueldeicaza/SwiftTerm.git "$source"
  fi
fi
if ! git -C "$source" cat-file -e "$revision^{commit}" 2>/dev/null; then
  git -C "$source" -c http.proxy=http://127.0.0.1:7897 fetch https://github.com/migueldeicaza/SwiftTerm.git "$revision"
fi
git -C "$source" checkout --detach "$revision"
if [ -n "$(git -C "$source" status --porcelain --untracked-files=all)" ]; then
  echo "SwiftTerm 源码目录存在修改，拒绝覆盖或构建。" >&2; exit 1
fi
if [ -d "$destination" ]; then rm -rf "$destination"; fi
mkdir -p "$destination"
git -C "$source" archive "$revision" Sources/SwiftTerm LICENSE | tar -x -C "$destination"
cp BuildSupport/SwiftTerm/Package.swift "$destination/Package.swift"
env -u SWIFTTERM_BUILD_BRANCH -u SWIFTTERM_BUILD_TAG -u SWIFTTERM_BUILD_COMMIT -u SWIFTTERM_BUILD_DIRTY \
  swift -frontend -interpret -parse-as-library -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" \
  "$source/Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift" -- "$source" "$destination/Sources/SwiftTerm/SwiftTermBuildInfo.swift"
printf '%s\n' "$revision" > "$destination/SOURCE_REVISION"
echo "PASS · SwiftTerm 1.20.0 固定源码与原生成器准备完成：$revision"
