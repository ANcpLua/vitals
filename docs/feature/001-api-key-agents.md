---
status: proposed
owner: unassigned
contact: ANcpLua
date: 2026-11-15
deciders: ANcpLua
---

# Show which session spends money through an API key

## What is the goal of this feature?

1. With many Claude Code sessions open, the user sees at a glance which one calls the
   Claude API with an API key through its tools (curl, an SDK script, a Managed Agents
   client), because those calls spend API credits or money while the session itself runs
   on the subscription. Hovering or clicking shows what it called, so the user can judge
   whether it uses the API sensibly or wastes it.
1. Success metric: with ten sessions open, the user names the session that used an API
   key within one look at the menu, and every API-key call from a session's own commands
   in the last 15 minutes is listed under it.
1. Outcome: a session that used an API key is marked `API` in the session list instead of
   its status dot; its calls are one hover away.

## What is the problem being solved?

1. Nothing local shows API-key use today. The Console shows usage per key with a delay and
   no link to a session. The transcript holds the commands, but nobody reads ten
   transcripts.
1. An agent that was handed a skill for Managed Agents or the SDK works in parallel with a
   managed environment behind it. It looks like every other session in the list.
1. Two sessions in one directory used to look alike; session titles fixed that (CHANGELOG,
   "Session rows say where the turn stands"), which this feature builds on.

## What we know

- Claude Code itself talks to `api.anthropic.com` for its own turns, as the session
  process. A program the session starts (Bash tool child: curl, python, node) that
  connects to the same API is API-key use. The process tree tells the two apart, however
  the call is made. Unverified: whether Claude Code's own helper processes also connect
  there; check with `lsof -i` on a live session before relying on it.
- `nettop -P -L 1` totals only cover open sockets (AGENTS.md); a connection that opens and
  closes between two samples is missed. A per-connection listing (`nettop -m tcp`, or
  `lsof -i -a -p <pid>`) on the session's descendants every 2 s catches anything that
  lasts a request; streaming and Managed Agents connections last long.
- The transcript records each Bash command with its timestamp. Commands that mention
  `api.anthropic.com`, `ANTHROPIC_API_KEY`, `x-api-key`, the `anthropic` SDK or `ant `
  give the call list. Key values are never read, in line with the key registry's rule.
- Granted API credits do not cover Claude Code itself, only API, SDK and Managed Agents
  calls (observed by the user).
- Admin API (checked 2026-11-15 against the bundled Claude API skill, `admin-api.md`):
  - An Admin API key (`sk-ant-admin...`) or an `org:admin` OAuth token is required;
    regular keys are rejected. Admin keys are created in the Console only.
  - `api_keys.update(id, status="inactive")` switches a single key off. That is the only
    per-key control.
  - `spend_limits` (set, read, list, delete) exists for the organization and for
    workspaces, not for single keys. For Console organizations it is an early-access
    preview that only some have; Claude Enterprise organizations have it in full.
  - Usage and cost come from the Usage and Cost Analytics API (`analytics.usage`,
    `analytics.cost`, beta), with a delay.

## Changes

| Surface | Change |
| --- | --- |
| Menu | A session that used an API key in the last 15 minutes shows an `API` badge instead of its status dot. Hover lists the calls (time, command, host); click copies them. Later, optionally: right-click offers "Switch this key off" and, where the organization has spend limits, "Limit this workspace to $X", each confirmed by the user. |
| CLI | `vitals api`: per session, the API-key calls of the last 15 minutes. |
| Registry | Only for the right-click actions: an Admin key entry in `keys.json` (`kind` as for other Keychain items). |

## Implementation

- `VitalsCore`: `ApiUse.decide(connections:sessions:)`, pure: which connections belong to
  which session (descendant of the session pid, not the pid itself) and count as
  Anthropic API. Selftest with made-up process trees.
- `VitalsKernel`: a sampler for the TCP connections of a set of pids with remote host,
  every 2 s while the menu is open or a session row needs it.
- `VitalsClaude`: transcript reader for the matching Bash commands, next to
  `TranscriptFacts`.
- Menu: the badge and tooltip in `ClaudeSectionView`; right-click actions only after the
  read-only part has shipped.

## E2E samples

```text
$ vitals api
session   Ping-Befehl fuer Upload-Test   pid 44862   API  3 calls in 15 min
  07:12  python3 dedupe_agent.py --session start      api.anthropic.com
  07:13  ant beta:sessions stream sesn_...            api.anthropic.com
  07:20  curl -s https://api.anthropic.com/v1/...     api.anthropic.com
session   Ancplua.analyzers, utils und sdk pid 44910   no API-key calls
```

## Out of scope

- Money spent per session: nami will monitor it; Vitals does not poll cost.
- Calls a Managed Agents session makes inside Anthropic's cloud: only the local client's
  connections are visible.

## Open questions

- Does Claude Code start helper processes that reach `api.anthropic.com` themselves?
  Settle with `lsof -i` on the descendants of a live session.
- How to recognise the API host: resolve `api.anthropic.com` at sample time, or Anthropic's
  published address ranges. Settle by checking the docs and comparing with live
  connections.
- Code mode (code.claude.com/docs/en/code-mode) runs tool calls as JavaScript and is said to
  drop some telemetry; check whether its calls still appear as child processes and in the
  transcript.

## Verification

- Selftest for `ApiUse.decide` and the transcript matcher.
- Live: a session runs `curl https://api.anthropic.com/v1/models` with a key; it gets the
  badge within one sample and the call in its tooltip; a session without such calls does
  not.
- `vitals sessions-preview` renders the badge.
