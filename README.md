# Vitals

Native Swift menu-bar telemetry for macOS: CPU, memory pressure, disk
headroom, processes with a 60 s per-process CPU sparkline, optional
per-process network rates via `nettop`, Claude usage plus copyable local
sessions, the MCP servers Claude Code sees with their callable tool names,
and stay-awake modes that hold the same power assertions and clamshell-sleep
override Clamshell.app does, without root. Disk headroom follows macOS's
capacity available for important usage, the value Finder reports, and also
shows the immediately free capacity.

## Clipboard

⌃⇧V opens a floating panel over the last 200 copied texts: type to filter,
↑↓ to move, ↩ or click to put an entry back on the pasteboard, then ⌘V
where you need it. Writes that password managers mark as concealed or
transient are never recorded. The history lives owner-only in
`~/Library/Application Support/Vitals/clipboard.json`; Clear empties it.

## Claude sessions and the Fable gate

Per live session the transcript under `~/.claude/projects` gives calls,
context per call and output rate for the last 15 minutes, shown in the
session row as `×10 · 350k ctx`. Cache reads of a large context dwarf
everything else, so the tooltip ranks by price-weighted tokens, never raw
tokens per minute. The usage bars show what the endpoint reports and nothing
more: no forecast, because a rate measured over a 15-minute burst says
nothing about the hours ahead, and the 5-hour window already stops a burst.

The one expensive action worth guarding is a subagent on Fable, since only
Fable counts against the weekly Fable limit. `install.sh` registers
`fable-subagent-gate.sh` as a Claude Code PreToolUse hook matched on the
`Agent` tool. It is silent unless the subagent would run on Fable: an explicit
`model: fable`, or no model where the agent definition has none and the calling
session's transcript shows Fable. Then it denies the call once with a reminder
the orchestrator has to answer: resend with `model: "opus"`, or resend the same
call within two minutes to keep Fable. It asks again at every fifth Fable
spawn. Every `Agent` call is logged to
`~/.config/vitals/agent-spawns/<session>.jsonl`, and the session row shows
the tally: `3 agents, 2 Fable`. `vitals burn` prints the same per session,
from local files only.

## API keys

`~/.config/vitals/keys.json` is an index of where secrets live, never of
their values: name, storage (`keychain` service and account, `environment`
variable, `file` path, or a `reference` Vitals does not check), the URL
where a key is created or revoked, a note for agents, and when the presence
check last passed. The menu row shows the counts; the submenu lists the
entries, opens the file, or re-checks. `vitals keys` prints the same for an
agent, `vitals keys init` writes an example. A CLAUDE.md line such as "run
`vitals keys` before asking for a credential" is the whole integration.

## Install

```bash
./install.sh
```

Builds `Vitals.app` in release mode with an ad-hoc signature, copies it to
`~/Applications/Vitals.app`, writes the `dev.ancplua.vitals` LaunchAgent and
(re)starts it. Run it again to update. Needs the Xcode Command Line Tools.

## Develop

```bash
swift run -c release selftest
swift run -c release claude-selftest
swift run -c release mcp-selftest
swift run -c release vitals snapshot
swift run -c release vitals claude
swift run -c release vitals mcp refresh
swift run -c release vitals awake
bash pack.sh build            # Vitals.app in ./build
```

Claude usage is read from the `Claude Code-credentials` Keychain item through
`/usr/bin/security`, which Claude Code itself uses to write it, so no Keychain
dialog is shown. Local Claude Code sessions come from
`~/.claude/sessions/<pid>.json` (or `$CLAUDE_CONFIG_DIR/sessions`).

Stay awake holds `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep`
and clears the kernel's clamshell-sleep flag through `kPMSetClamshellSleepState`
on the `IOPMrootDomain` user client, which macOS accepts from any process. The
lid and display modes arm the flag only while an external display is attached,
so a closed lid in a bag still sleeps; Always arms it regardless. Clamshell.app
flips the same flag, so run one of the two.
