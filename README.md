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

⌃⇧V opens a floating panel over the last 200 copied texts and images: type
to filter, ↑↓ to move, ↩ or click to put an entry back on the pasteboard,
then ⌘V where you need it. Copied images show as a thumbnail with their
size, the newest 30 are kept as PNG in `clipboard-images`, and a copy
carrying text keeps the text. Writes that password managers mark as
concealed or transient are never recorded. The history lives owner-only in
`~/Library/Application Support/Vitals/clipboard.json`; Clear empties it and
deletes the image files.

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

`~/.config/vitals/keys.json` indexes credential locations, never their values.
Presence and authentication are separate. A file or GitHub secret can exist while
its credential is expired, revoked, or scoped to the wrong resource.

- `vitals keys` checks local presence, GitHub secret metadata, and recent
  credential-health workflow results. The menu refreshes these every ten minutes.
- `vitals keys check`, or **API keys > Test local credentials**, also performs
  the configured local read-only provider checks. Local credential values are
  read only for this explicit action, stay in memory, and are never printed.
- **Re-check now** refreshes metadata and remote results without reading local
  secret values or dispatching workflows. Hover an entry for individual results,
  timestamps, and workflow links. New credential failures trigger a notification.
- Local authentication results expire after 24 hours. Remote results also expire
  after 24 hours, and a secret updated after a run immediately makes that run stale.
  Network errors, missing access, skipped jobs, and unconfigured probes never count
  as authenticated. Claude uses its existing usage poll, without another request.

Optional entry fields configure checks:

```json
{
  "name": "Production Railway",
  "kind": "reference",
  "reference": "GitHub Actions secret RAILWAY_TOKEN in owner/repo",
  "remoteChecks": [{
    "repository": "owner/repo",
    "secrets": ["RAILWAY_TOKEN"],
    "workflow": "credential-health.yml",
    "job": "railway"
  }]
}
```

Local checks use `localCheck` with a `provider` (`chrome`, `amo`, `edge`,
`auth0`, or `claude`), credential paths (`envFile`, `clientFile`, `refreshFile`),
an AMO `keychainService`, and non-secret `options`. Existing entries still load.
The probe uses only Python's standard library, preferring `~/.local/bin/pytools`
and otherwise the Command Line Tools Python. It is bundled with the app.

The read-only remote workflow runs on a six-hour schedule and on demand, with
secret values available only to its probe step. Railway checks exact project and
environment IDs. GitHub release credentials must have repository write permission.
Chrome checks OAuth and item access; AMO checks the authenticated profile. Edge
requires a real previous publishing operation: a 404 is not authentication proof.
Local Chrome checks without a publisher ID establish OAuth and Web Store scope
only. Hosted MCP checks exchange the Auth0 refresh token, save a rotated token
back to the same Keychain item, then call authenticated `server/discover` at the hosted MCP revision.
These checks do not upload, publish, deploy, or pay invoices. Unexpected revocation
can still happen between checks; monitoring detects failure rather than preventing it.

The safe result cache is `~/.config/vitals/key-health.json` (owner-only). No secret
values enter it. GitHub's existing `gh` login needs read access to repository secret
metadata and Actions runs. Authentication checks return fixed result categories,
never provider response bodies or credential-bearing exception messages.

### Registry format and recovery

The versioned JSON schema is [`schema/keys.schema.json`](schema/keys.schema.json).
Swift decoding and menu policy live in `Sources/VitalsCore/Keys.swift`, storage and
recovery in `Sources/VitalsKernel/KeyChecks.swift`, and authentication probes in
`Sources/VitalsKernel/credential_health.py`. These ship in this Git repository;
the probe is also bundled with the installed app. Each monitored repository keeps
its own `.github/workflows/credential-health.yml` independently of this Mac.

Your personal registry is `~/.config/vitals/keys.json`, outside the app and Git
checkout. After a successful load or save, Vitals keeps a validated, owner-only
copy at `~/.config/vitals/keys.last-good.json`. Invalid or unreadable files never
replace that copy. If the registry is deleted or corrupted, choose **Restore saved
registry**, or run `vitals keys restore`. Recovery preserves a damaged original as
`keys.damaged-<id>.json` and refuses to replace an already valid registry. `keys init`
never overwrites an existing file and offers recovery when a saved copy exists.

The recovery copy contains locations and configuration, not credential values.
It does not replace a backup of Keychain or credential files, and deleting the
entire configuration directory deletes both registry copies. Include that directory
in your normal Mac backup. The disposable `key-health.json` cache can be rebuilt
with **Re-check now** and **Test local credentials**. Reinstalling the app leaves
the registry and credentials intact.

Entries appear immediately while checks run; a slow check never makes an existing
registry look missing. **Open keys.json** only opens the file and cannot reset it.

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
