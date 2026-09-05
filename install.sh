#!/usr/bin/env bash
# Build Vitals.app, copy it to ~/Applications and (re)start the LaunchAgent.
# Run again to update. Needs the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

label=dev.ancplua.vitals
app="$HOME/Applications/Vitals.app"
plist="$HOME/Library/LaunchAgents/$label.plist"

bash pack.sh build
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$app"
cp -R build/Vitals.app "$app"
sed "s|{app}|$app|" "launchd/$label.plist" > "$plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
"$app/Contents/MacOS/vitals" snapshot > /dev/null
echo "installed $app · agent $label running"
