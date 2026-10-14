#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=release
architectures=(arm64 x86_64)
if [ "${1:-}" = "--debug" ]; then configuration=debug; architectures=("$(uname -m)"); fi
if [ "${1:-}" = "--arm64-only" ]; then architectures=(arm64); fi
if nc -z -w 1 127.0.0.1 7897 2>/dev/null; then
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://127.0.0.1:7897
fi
export GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=20
for architecture in "${architectures[@]}"; do
  if [ "$architecture" = "x86_64" ]; then
    swift build --build-system native -c "$configuration" --arch "$architecture" -Xswiftc -runtime-compatibility-version -Xswiftc none
  else
    swift build --build-system native -c "$configuration" --arch "$architecture"
  fi
done
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
mkdir -p .build/AppIcon.iconset dist
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
artifacts=()
for architecture in "${architectures[@]}"; do
app="$PWD/dist/$architecture/Farport.app"
if [ -d "$app" ]; then rm -rf "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp .build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for executable in SSHWorkbench workbench-askpass; do
  cp ".build/$architecture-apple-macosx/$configuration/$executable" "$app/Contents/MacOS/$executable"
  [ "$(lipo -archs "$app/Contents/MacOS/$executable")" = "$architecture" ]
  codesign --force --sign - --timestamp=none "$app/Contents/MacOS/$executable"
done
resource=".build/$architecture-apple-macosx/$configuration/SwiftTerm_SwiftTerm.bundle"
cp -R "$resource" "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/ThirdParty/SwiftTerm-LICENSE.txt"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
lipo -info "$app/Contents/MacOS/SSHWorkbench"
if [ "$configuration" = "release" ]; then
  suffix="$architecture"
  archive="$PWD/dist/Farport-$version-$suffix.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
  staging="$PWD/.build/dmg-staging-$architecture"
  mkdir -p "$staging"
  if [ -d "$staging/SSH Workbench.app" ]; then rm -rf "$staging/SSH Workbench.app"; fi
  if [ -d "$staging/Farport.app" ]; then rm -rf "$staging/Farport.app"; fi
  cp -R "$app" "$staging/Farport.app"
  ln -sfn /Applications "$staging/Applications"
  hdiutil create -volname "Farport" -srcfolder "$staging" -ov -format UDZO "$PWD/dist/Farport-$version-$suffix.dmg"
  artifacts+=("Farport-$version-$suffix.dmg" "Farport-$version-$suffix.zip")
fi
printf '\n应用已生成：%s\n' "$app"
done
native="$(uname -m)"
if [ -d "dist/$native/Farport.app" ]; then
  if [ -d dist/Farport.app ]; then rm -rf dist/Farport.app; fi
  ditto "dist/$native/Farport.app" dist/Farport.app
fi
if [ "${#artifacts[@]}" -gt 0 ]; then (cd dist && shasum -a 256 "${artifacts[@]}" > "Farport-$version-SHA256SUMS"); fi
