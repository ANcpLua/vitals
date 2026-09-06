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

# Register the Fable subagent gate: one PreToolUse entry matched on the
# Agent tool in ~/.claude/settings.json, pointing at the script inside the
# bundle. Any earlier Vitals hook entry is replaced.
python3 - "$app/Contents/Resources/fable-subagent-gate.sh" <<'PY'
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
command = sys.argv[1].replace(os.path.expanduser("~"), "$HOME", 1)
try:
    settings = json.load(open(path))
except FileNotFoundError:
    settings = {}
hooks = settings.setdefault("hooks", {})
groups = hooks.get("PreToolUse", [])
def is_vitals(group):
    return any(h.get("command", "").endswith(("fable-subagent-gate.sh", "budget-warning.sh")) for h in group.get("hooks", []))
kept = [g for g in groups if not is_vitals(g)]
kept.append({"matcher": "Agent", "hooks": [{"type": "command", "command": command, "timeout": 5}]})
if kept == groups:
    print("hook already registered")
    sys.exit(0)
hooks["PreToolUse"] = kept
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("fable-subagent-gate registered as PreToolUse(Agent) in ~/.claude/settings.json")
PY
echo "installed $app · agent $label running"
