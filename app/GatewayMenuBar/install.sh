#!/bin/bash
# Builds Gateway.app (if needed), installs it to /Applications, and sets
# it to start at login via a LaunchAgent. Run from this directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

if [ ! -d "Gateway.app" ] || [ "${1:-}" = "--rebuild" ]; then
  bash build.sh
fi

echo "--- installing to /Applications ---"
rm -rf /Applications/Gateway.app
cp -R "$here/Gateway.app" /Applications/Gateway.app

echo "--- installing login LaunchAgent ---"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$here/com.local.gateway-menubar.plist" "$HOME/Library/LaunchAgents/com.local.gateway-menubar.plist"
launchctl bootout "gui/$(id -u)/com.local.gateway-menubar" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.local.gateway-menubar.plist"

echo ""
echo "Installed. Gateway.app is in /Applications and will start on login."
echo "It's running now -- look for the icon in your menu bar."
echo ""
echo "To uninstall:"
echo "  launchctl bootout gui/\$(id -u)/com.local.gateway-menubar"
echo "  rm ~/Library/LaunchAgents/com.local.gateway-menubar.plist"
echo "  rm -rf /Applications/Gateway.app"
