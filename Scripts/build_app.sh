#!/bin/zsh
# Builds build/Postvak.app without Xcode. Usage: Scripts/build_app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Postvak
BIN=".build/$CONFIG/Postvak"
APP="build/Postvak.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Postvak"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift Scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles sit in Contents/Resources; the app's Bundle.module falls back to the build folder.
for b in .build/$CONFIG/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
codesign --force --deep --sign - --identifier be.postvak.app "$APP"
echo "Built $PWD/$APP"
