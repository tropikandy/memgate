#!/bin/bash
# Builds Gateway.app from this SwiftPM package: compiles the release
# binary, assembles a real .app bundle (Info.plist + icon), and
# ad-hoc code-signs it (no Apple Developer certificate needed for
# local-only use on this machine).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_name="Gateway.app"
build_dir="$here/.build/release"
app_dir="$here/$app_name"

echo "--- building release binary ---"
cd "$here"
swift build -c release

echo "--- assembling $app_name ---"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/GatewayMenuBar" "$app_dir/Contents/MacOS/GatewayMenuBar"
cp "$here/Info.plist" "$app_dir/Contents/Info.plist"
cp "$here/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

echo "--- ad-hoc code signing ---"
codesign --force --deep --sign - "$app_dir"

echo "--- done: $app_dir ---"
echo "Run it directly with: open \"$app_dir\""
echo "Or install to /Applications with: cp -R \"$app_dir\" /Applications/"
