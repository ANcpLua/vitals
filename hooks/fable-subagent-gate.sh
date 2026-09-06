#!/bin/bash
# Claude Code PreToolUse hook, matcher "Agent". Silent unless the subagent about
# to be spawned would run on Fable. Then it denies the call once with a reminder
# the orchestrator has to answer: resend with model "opus", or resend the same
# call to keep Fable (the retry within the grace window passes). Re-asks every
# ASK_EVERY Fable spawns so a fleet gets a second look. Logs every Agent spawn
# per session to ~/.config/vitals/agent-spawns/<session>.jsonl for Vitals.
HOOK_INPUT="$(cat 2>/dev/null)" python3 - <<'PY' 2>/dev/null
import json, os, re, sys, time, glob
GRACE_SECONDS = 120
ASK_EVERY = 5
raw = os.environ.get("HOOK_INPUT", "")
try:
    inp = json.loads(raw)
except Exception:
    sys.exit(0)
if inp.get("tool_name") != "Agent":
    sys.exit(0)
ti = inp.get("tool_input") or {}
session = inp.get("session_id", "unknown")
cwd = inp.get("cwd") or os.getcwd()
transcript = inp.get("transcript_path") or ""
home = os.path.expanduser("~")

def parent_model():
    """Model of the calling session: last assistant entry in its transcript."""
    try:
        with open(transcript, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 400_000))
            lines = f.read().decode("utf-8", "replace").splitlines()
        for line in reversed(lines):
            if '"model"' not in line: continue
            try: e = json.loads(line)
            except Exception: continue
            m = (e.get("message") or {}).get("model")
            if m: return m
    except Exception:
        pass
    return "unknown"

def agent_definition_model(kind):
    if not kind: return None
    paths = [os.path.join(cwd, ".claude", "agents", f"{kind}.md"),
             os.path.join(home, ".claude", "agents", f"{kind}.md")]
    paths += glob.glob(os.path.join(home, ".claude", "plugins", "cache", "*", "*", "*", "agents", f"{kind}.md"))
    for p in paths:
        try:
            head = open(p, encoding="utf-8", errors="replace").read(4000)
        except Exception:
            continue
        m = re.search(r"^model:\s*([^\s#]+)", head, re.M)
        return m.group(1).strip().strip('"\'') if m else None
    return None

model = (ti.get("model") or "").strip().lower()
kind = (ti.get("subagent_type") or "").strip()
source = "explicit"
if not model:
    if kind == "fork":
        model, source = parent_model(), "fork inherits parent"
    else:
        d = agent_definition_model(kind)
        if d and d.lower() not in ("inherit", "default"):
            model, source = d.lower(), f"agent definition {kind}"
        else:
            model, source = parent_model(), "inherits parent"
# Unknown parent on this machine means the user default, which is Fable.
is_fable = ("fable" in model) or model == "unknown"

log_dir = os.path.join(home, ".config", "vitals", "agent-spawns")
os.makedirs(log_dir, exist_ok=True)
log_path = os.path.join(log_dir, f"{session}.jsonl")
entries = []
try:
    with open(log_path, encoding="utf-8") as f:
        entries = [json.loads(l) for l in f if l.strip()]
except Exception:
    pass
now = time.time()
spawned = [e for e in entries if not e.get("denied")]
n = len(spawned) + 1
m = sum(1 for e in spawned if e.get("fable")) + (1 if is_fable else 0)

def log(denied):
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"t": now, "model": model, "source": source, "type": kind,
                            "fable": is_fable, "denied": denied,
                            "description": (ti.get("description") or "")[:80]}) + "\n")

if not is_fable:
    log(False); sys.exit(0)

# Any recent denial opens the grace window, so a parallel batch that got one
# reminder is not asked again for every sibling that happened to log later.
in_grace = any(e.get("denied") and now - e.get("t", 0) < GRACE_SECONDS for e in entries)
should_ask = (not in_grace) and (m == 1 or m % ASK_EVERY == 0)
if not should_ask:
    log(False); sys.exit(0)

log(True)
reason = (
    f"Friendly reminder from Vitals, not a failure: this session has now sent {n} subagent call(s), "
    f"{m} of them on Fable, this one included (model resolved from: {source}). "
    "Are you confident Fable is the right choice for this task, and is it low or high effort? "
    "Would Opus 5 be worse here? If yes, keep Fable: send this exact call again within 2 minutes and it goes through. "
    "If not, resend it with model: \"opus\" (or \"sonnet\" for low-effort work). "
    "The user watches the weekly Fable limit; Opus subagents do not count against it."
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "permissionDecision": "deny",
                                         "permissionDecisionReason": reason}}))
PY
exit 0
