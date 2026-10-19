#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=release
architectures=(arm64 x86_64)
preview=false
for argument in "$@"; do
  case "$argument" in
    --debug) configuration=debug; architectures=("$(uname -m)") ;;
    --arm64-only) architectures=(arm64) ;;
    --preview) preview=true ;;
    *) echo "用法：$0 [--debug] [--arm64-only] [--preview]" >&2; exit 2 ;;
  esac
done
appName=Farport
outputRoot="$PWD/dist"
variant=""
if [ "$preview" = true ]; then appName="Farport Preview"; outputRoot="$PWD/dist/preview"; variant="-preview"; fi
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
archiveBase="Farport-$version$variant"
mkdir -p .build/AppIcon.iconset "$outputRoot"
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
artifacts=()
packages=("${architectures[@]}")
if [ "${#architectures[@]}" -eq 2 ]; then packages+=(universal); fi
for architecture in "${packages[@]}"; do
app="$outputRoot/$architecture/$appName.app"
if [ -d "$app" ]; then rm -rf "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ "$preview" = true ]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Farport Preview' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 栖远 Farport 预览' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.sshworkbench.preview' "$app/Contents/Info.plist"
fi
install -m 644 LICENSE "$app/Contents/Resources/LICENSE.txt"
cp .build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for executable in SSHWorkbench workbench-askpass; do
  if [ "$architecture" = universal ]; then
    lipo -create ".build/arm64-apple-macosx/$configuration/$executable" ".build/x86_64-apple-macosx/$configuration/$executable" -output "$app/Contents/MacOS/$executable"
    for requiredArchitecture in arm64 x86_64; do lipo -verify_arch "$requiredArchitecture" "$app/Contents/MacOS/$executable"; done
  else
    cp ".build/$architecture-apple-macosx/$configuration/$executable" "$app/Contents/MacOS/$executable"
    [ "$(lipo -archs "$app/Contents/MacOS/$executable")" = "$architecture" ]
  fi
  codesign --force --sign - --timestamp=none "$app/Contents/MacOS/$executable"
done
resourceArchitecture="$architecture"
if [ "$architecture" = universal ]; then resourceArchitecture=arm64; fi
resource=".build/$resourceArchitecture-apple-macosx/$configuration/SwiftTerm_SwiftTerm.bundle"
cp -R "$resource" "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp -R ".build/$resourceArchitecture-apple-macosx/$configuration/SSHWorkbench_WorkbenchCore.bundle" "$app/Contents/Resources/SSHWorkbench_WorkbenchCore.bundle"
cp -R ".build/$resourceArchitecture-apple-macosx/$configuration/SSHWorkbench_OpenSSHBackend.bundle" "$app/Contents/Resources/SSHWorkbench_OpenSSHBackend.bundle"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/ThirdParty/SwiftTerm-LICENSE.txt"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
lipo -info "$app/Contents/MacOS/SSHWorkbench"
if [ "$configuration" = "release" ]; then
  suffix="$architecture"
  archive="$outputRoot/$archiveBase-$suffix.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
  staging="$PWD/.build/dmg-staging$variant-$architecture"
  mkdir -p "$staging"
  if [ -d "$staging/SSH Workbench.app" ]; then rm -rf "$staging/SSH Workbench.app"; fi
  if [ -d "$staging/$appName.app" ]; then rm -rf "$staging/$appName.app"; fi
  cp -R "$app" "$staging/$appName.app"
  ln -sfn /Applications "$staging/Applications"
  hdiutil create -volname "$appName" -srcfolder "$staging" -ov -format UDZO "$outputRoot/$archiveBase-$suffix.dmg"
  artifacts+=("$archiveBase-$suffix.dmg" "$archiveBase-$suffix.zip")
fi
printf '\n应用已生成：%s\n' "$app"
done
native="$(uname -m)"
if [ -d "$outputRoot/$native/$appName.app" ]; then
  if [ -d "$outputRoot/$appName.app" ]; then rm -rf "$outputRoot/$appName.app"; fi
  ditto "$outputRoot/$native/$appName.app" "$outputRoot/$appName.app"
fi
if [ "${#artifacts[@]}" -gt 0 ]; then (cd "$outputRoot" && shasum -a 256 "${artifacts[@]}" > "$archiveBase-SHA256SUMS"); fi
