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
domain="gui/$(id -u)"
launchctl bootout "$domain/$label" 2>/dev/null || true
# bootout returns before the service is gone; bootstrapping too early fails
# with "Input/output error".
for _ in $(seq 1 50); do
    launchctl print "$domain/$label" > /dev/null 2>&1 || break
    sleep 0.1
done
launchctl bootstrap "$domain" "$plist"
"$app/Contents/MacOS/vitals" snapshot > /dev/null
echo "installed $app · agent $label running"
