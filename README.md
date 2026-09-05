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

## Claude budget

The usage endpoint reports percentages only, so Vitals samples them once a
minute and forecasts each limit from the last 15 minutes: "empty in 3h 20m,
resets in 6d". A limit that runs out before its reset is a warning: the bar
turns amber (coral under an hour), a notification fires once, a line under
the usage rows names the session burning most tokens (click it to send that
session SIGINT, the same interrupt as Esc), and
`~/.config/vitals/budget-warning.json` is written for agents. Absolute
tokens per session come from the transcripts under `~/.claude/projects`.

`install.sh` registers `budget-warning.sh` as a Claude Code PreToolUse hook.
While a warning is active and fresh it hands the advice to a running agent
as additional context, once per session per 10 minutes; it always exits 0
and cannot block a tool call. `vitals budget` prints the same picture.

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
