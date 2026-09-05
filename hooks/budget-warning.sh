#!/bin/bash
# Claude Code PreToolUse hook. Surfaces an active Vitals budget warning to the
# running agent as additional context, at most once per session per 10
# minutes, and only while the warning file is fresh. Never blocks: exit 0 on
# every path, output only when there is something to say.
file="$HOME/.config/vitals/budget-warning.json"
[ -f "$file" ] || exit 0
# The hook's own JSON arrives on stdin; read it here because the heredoc
# below occupies python's stdin.
HOOK_INPUT="$(cat 2>/dev/null)" python3 - "$file" <<'PY' 2>/dev/null
import json, os, sys, time
from datetime import datetime, timezone
try:
    warning = json.load(open(sys.argv[1]))
    if not warning.get("active"):
        sys.exit(0)
    updated = datetime.fromisoformat(warning["updatedAt"].replace("Z", "+00:00"))
    if (datetime.now(timezone.utc) - updated).total_seconds() > 600:
        sys.exit(0)
    try:
        session = json.loads(os.environ.get("HOOK_INPUT", "")).get("session_id", "unknown")
    except Exception:
        session = "unknown"
    stamp_dir = os.path.expanduser("~/.config/vitals/budget-warning-stamps")
    os.makedirs(stamp_dir, exist_ok=True)
    stamp = os.path.join(stamp_dir, f"{session}.stamp")
    try:
        if time.time() - os.path.getmtime(stamp) < 600:
            sys.exit(0)
    except OSError:
        pass
    open(stamp, "w").close()
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": warning.get("advice", "")}}))
except SystemExit:
    raise
except Exception:
    pass
PY
exit 0
