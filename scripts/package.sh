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
app="$PWD/dist/Farport.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty" .build/AppIcon.iconset
if [ -d "$app/SwiftTerm_SwiftTerm.bundle" ]; then rm -rf "$app/SwiftTerm_SwiftTerm.bundle"; fi
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
for executable in SSHWorkbench workbench-askpass; do
  inputs=()
  for architecture in "${architectures[@]}"; do inputs+=(".build/$architecture-apple-macosx/$configuration/$executable"); done
  if [ "${#inputs[@]}" -gt 1 ]; then lipo -create "${inputs[@]}" -output "$app/Contents/MacOS/$executable.new"; else cp "${inputs[0]}" "$app/Contents/MacOS/$executable.new"; fi
  mv -f "$app/Contents/MacOS/$executable.new" "$app/Contents/MacOS/$executable"
  codesign --force --sign - --timestamp=none "$app/Contents/MacOS/$executable"
done
resource=".build/${architectures[0]}-apple-macosx/$configuration/SwiftTerm_SwiftTerm.bundle"
if [ -d "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle" ]; then rm -rf "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"; fi
cp -R "$resource" "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/ThirdParty/SwiftTerm-LICENSE.txt"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
lipo -info "$app/Contents/MacOS/SSHWorkbench"
if [ "$configuration" = "release" ]; then
  suffix=universal
  if [ "${#architectures[@]}" -eq 1 ]; then suffix="${architectures[0]}"; fi
  archive="$PWD/dist/Farport-$version-$suffix.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
  staging="$PWD/.build/dmg-staging"
  mkdir -p "$staging"
  if [ -d "$staging/SSH Workbench.app" ]; then rm -rf "$staging/SSH Workbench.app"; fi
  if [ -d "$staging/Farport.app" ]; then rm -rf "$staging/Farport.app"; fi
  cp -R "$app" "$staging/Farport.app"
  ln -sfn /Applications "$staging/Applications"
  hdiutil create -volname "Farport" -srcfolder "$staging" -ov -format UDZO "$PWD/dist/Farport-$version-$suffix.dmg"
  (cd dist && shasum -a 256 "Farport-$version-$suffix.dmg" "Farport-$version-$suffix.zip" > "Farport-$version-SHA256SUMS")
fi
printf '\n应用已生成：%s\n' "$app"
