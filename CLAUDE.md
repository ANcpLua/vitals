# Vitals

Native Swift macOS menu-bar app. Repository https://github.com/ANcpLua/vitals,
standalone since 2026-09-05 (before: `tools/vitals` in ANcpLua/human-plugins).
Local clone: `~/Developer/vitals`. Installed copy: `~/Applications/Vitals.app`,
LaunchAgent `dev.ancplua.vitals`.

For a new Mac, an empty registry, reinstalling, lost configuration, or setting up
credential monitoring, follow [docs/agent-setup.md](docs/agent-setup.md). This is
the setup and recovery procedure; it does not depend on previous chat context.

## Commands

```bash
bash pack.sh build                                  # Vitals.app in ./build, ad-hoc signed
build/swift/release/selftest                        # kernel + core (pure policy, IOKit, signals, clipboard, keys)
build/swift/release/claude-selftest                 # telemetry parsing, alerts, transcripts, spawn log
build/swift/release/mcp-selftest
build/Vitals.app/Contents/MacOS/vitals keys-menu-selftest # loading state and existing Claude authentication
python3 scripts/test_credential_health.py
python3 scripts/test_install_hook.py
./install.sh                                        # build, copy to ~/Applications, (re)start the agent, register the hook
build/swift/release/vitals snapshot|claude|burn|keys|mcp|awake     # headless views, no menu needed
```

CI (`.github/workflows/ci.yml`, macos-15) is the check list. For runtime or installer
changes, run its relevant tests locally and `./install.sh`; add a CHANGELOG line,
push the commit and wait for green CI. For documentation-only changes, verify
paths, commands and examples against source, push, and wait for CI; reinstalling
an unchanged binary is unnecessary.

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
  `changeCount` polled every 0.5 s, `org.nspasteboard.ConcealedType`,
  `TransientType`, `AutoGeneratedType` never recorded, 200 entries owner-only in
  Application Support. Text wins when a write carries both text and a picture;
  otherwise the PNG or TIFF is normalized to PNG and written to
  `clipboard-images/<sha256>.png` (owner-only, dir 0700) with only the digest,
  size and dimensions in the JSON, so equal images collapse and the file stays
  small. Newest 30 images, nothing over 16 MB, orphan files pruned on every save
  and at launch; `ClipboardThumbnails` decodes one thumbnail per digest because
  the panel rebuilds its rows on every keystroke. Image rows are taller
  (`heightOfRow`), so never set a single `rowHeight` again. Panel is a `.nonactivatingPanel` so the target app keeps
  focus; pasting is the user's ⌘V. Hotkey ⌃⇧V through Carbon `RegisterEventHotKey`
  (no Accessibility needed). On the user's Sculpt keyboard ⌃ is the Windows key.
- **Keys** (`Keys.swift`, `KeyChecks.swift`): `~/.config/vitals/keys.json` is an index
  of credential locations and check configuration. Presence uses Keychain metadata,
  file size, or environment definitions. Authentication is separate: background
  checks read GitHub secret metadata and workflow evidence; local secret values are
  read only through explicit **Test local credentials** / `vitals keys check`.
  Auth0 refresh rotation is saved before the subsequent MCP request. Claude reuses
  its existing usage poll. Values stay out of UI, logs, registry, examples, and Git.
  Load entries before starting asynchronous checks. Preserve the validated
  `keys.last-good.json`; `keys restore` is explicit and preserves corrupt originals.
  See the setup guide for provider formats, remote workflow installation, and recovery.
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
