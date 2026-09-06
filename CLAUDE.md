# Vitals

Native Swift macOS menu-bar app. Repository https://github.com/ANcpLua/vitals,
standalone since 2026-09-05 (before: `tools/vitals` in ANcpLua/human-plugins).
Local clone: `~/repo-playground/vitals`. Installed copy: `~/Applications/Vitals.app`,
LaunchAgent `dev.ancplua.vitals`.

## Commands

```bash
bash pack.sh build                                  # Vitals.app in ./build, ad-hoc signed
build/swift/release/selftest                        # kernel + core (pure policy, IOKit, signals, clipboard, keys)
build/swift/release/claude-selftest                 # telemetry parsing, alerts, transcripts, spawn log
build/swift/release/mcp-selftest
./install.sh                                        # build, copy to ~/Applications, (re)start the agent, register the hook
build/swift/release/vitals snapshot|claude|burn|keys|mcp|awake     # headless views, no menu needed
```

CI (`.github/workflows/ci.yml`, macos-15) runs exactly these plus `plutil -lint`
and `codesign --verify`. A change is done when all three selftests pass locally,
`./install.sh` ran, CHANGELOG has a line, the commit is pushed and CI is green.

Toolchain: Command Line Tools only, no Xcode, so no XCTest. Selftests are plain
executables that `fail()` on the first broken expectation. The CI runner has an
older Swift than the local 6.3: write `let x: CGFloat = 16`, never mix `16.0`
literals with `bounds.width` in one expression.

## Layout

| Target | Role |
|---|---|
| `VitalsCore` | Pure policy, no I/O: `Awake`, `Alarm`, `Derive`, `ClipboardHistory`, `KeyRegister`, process history. Everything here is exercised by `selftest`. |
| `VitalsKernel` | Facts from the OS: `Sampler` (proc_pidinfo), `PowerSampler` + `AwakeAssertions` (IOKit), `NetworkSampler` (nettop), `Signals`, `ClipboardStore`, `KeyChecks`. |
| `VitalsClaude` | `~/.claude` and Anthropic endpoints: status, usage, sessions, transcripts (`ClaudeBurn.swift`: `SessionBurn`, `AgentSpawns`). |
| `VitalsMCP` | MCP servers Claude Code sees, probe, per-project toggle. |
| `vitals` | AppKit menu (`MenuBar.swift` is the controller), section views, `ClipboardPanel`, `HotKey`, CLI in `main.swift`. |

Pattern for every feature: a pure `decide`/`counts`/`adding` function in Core
or Claude with a selftest, a kernel reader, and the menu only wiring the two.
Menu items are rebuilt on every open; views that must update in place while the
menu is open do so through `update(model)` returning `false` when the row count
changed (`layoutSignature`). The menu must not get longer: new features get one
row and a submenu or their own panel.

## Feature notes and traps

- **Stay awake** (`Awake.swift`, `Power.swift`): holds `PreventUserIdleSystemSleep`
  and `PreventUserIdleDisplaySleep` and clears the kernel clamshell-sleep flag
  through `kPMSetClamshellSleepState` (selector 12) on the `IOPMrootDomain` user
  client. No root, no daemon; the kernel accepts it from any process. The flag is
  one shared bit: Clamshell.app flips the same one, and clearing it with the lid
  closed on battery sleeps the Mac at once. Lid and display modes arm it only
  with an external display attached; Always arms it regardless. Re-sent every
  2 s while wanted, cleared on Quit and on Off, not on SIGTERM.
- **Claude usage** (`ClaudeTelemetry.swift`): `api.anthropic.com/api/oauth/usage`
  answers HTTP 429 when polled more than about once a minute, and Claude Code
  polls it too. A failed poll keeps the last rows (`keepingUsage(from:)`); never
  add a second poller. Token comes from the `Claude Code-credentials` Keychain
  item via `/usr/bin/security`; a denied read suspends polling until Refresh.
- **Session burn and the Fable gate** (`ClaudeBurn.swift`, `hooks/fable-subagent-gate.sh`):
  per session the transcript
  `~/.claude/projects/<cwd with non-alphanumerics as dashes>/<sessionId>.jsonl`
  is tail-read (1 MB); assistant lines are deduplicated by `message.id` (streaming
  writes one line per content block). Cache reads dwarf everything because every
  call re-reads the context, so show calls and context (`×10 · 350k ctx`) and rank
  by price-weighted tokens, never raw tokens per minute. There is deliberately no
  usage forecast and no agent-facing budget text: a 15-minute rate says nothing
  about the hours ahead, and advice an agent may ignore is noise. Do not bring
  either back. The hook is copied into the bundle and registered by `install.sh`
  as PreToolUse with `matcher: "Agent"`; it reads hook stdin before the heredoc,
  exits 0 always, and denies (never `additionalContext`) so the reminder cannot be
  skipped. It resolves the model from the call, else the agent definition, else the
  parent transcript's last `message.model`; unknown counts as Fable. Log per session
  in `~/.config/vitals/agent-spawns/`, read back as `SpawnCounts`.
- **Clipboard** (`Clipboard.swift`, `ClipboardMonitor.swift`, `ClipboardPanel.swift`):
  `changeCount` polled every 0.5 s, text only, `org.nspasteboard.ConcealedType`,
  `TransientType`, `AutoGeneratedType` never recorded, 200 entries owner-only in
  Application Support. Panel is a `.nonactivatingPanel` so the target app keeps
  focus; pasting is the user's ⌘V. Hotkey ⌃⇧V through Carbon `RegisterEventHotKey`
  (no Accessibility needed). On the user's Sculpt keyboard ⌃ is the Windows key.
- **Keys** (`Keys.swift`, `KeyChecks.swift`): `~/.config/vitals/keys.json` is an index
  of where secrets live, never values. Keychain presence via
  `security find-generic-password -s` without `-w` (metadata, never prompts, exit
  44 = missing). Nothing in this feature may read, show or copy a value.
- **launchd**: `launchctl bootout` returns before the service is gone; `install.sh`
  polls before `bootstrap`, otherwise bootstrap fails with I/O error 5 and Vitals
  is down.
- **Network per process**: `nettop -P -L 1` totals only cover open sockets; a
  connection that opens and closes between ticks never shows.

## Conventions

- Commit: one short subject line plus the `Co-Authored-By: Claude Fable 5.1
  <noreply@anthropic.com>` trailer, no body. Push to `main`, wait for CI.
- CHANGELOG under `## Unreleased`, Keep a Changelog style, one bullet per change.
- No em dashes, no emoji in text shown to the user.
- Don't run `vitals claude` in a loop: each call spends one of the usage
  endpoint's requests and the menu bar's next poll gets a 429. `vitals burn`
  reads local files only and is safe to repeat.
