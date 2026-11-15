---
# A feature proposal an agent can own from idea to release. Copy this file to
# NNN-short-name.md (next free number), fill it in, keep it current while you build.
# Optional fields may be removed.
status: {proposed | accepted | in progress | shipped | rejected | superseded by [NNN](NNN-name.md)}
owner: {the agent or person who builds it}
contact: {who proposed it}
date: {YYYY-MM-DD of the last change to this file}
deciders: {who decides whether it ships}
consulted: {experts asked, two-way}
informed: {kept up to date, one-way}
---

# {short title: the problem and the solution}

## What is the goal of this feature?

Cover:
1. The value for the user
1. One success metric
1. The outcome, described without the implementation

## What is the problem being solved?

Cover:
1. Why it is hard today
1. The user's pain points
1. What it removes or simplifies (fewer tools, less looking elsewhere, less cost)

## What we know

Facts checked against source, docs or a live run, each with where it was checked. Mark
anything unverified as such. Constraints that shape the design belong here.

## Changes

List every change a user or agent can see, per surface. Remove the rows that do not apply.

| Surface | Change |
| --- | --- |
| Menu (one row, its own panel, or a badge; the menu must not get longer) | |
| CLI (`vitals <command>`) | |
| Registry or schema (`keys.json`, `schema/keys.schema.json`) | |
| Files, settings, permissions | |

## Implementation

Follow the pattern in `AGENTS.md`: a pure `decide`/`counts`/`adding` function in
`VitalsCore` or `VitalsClaude` with a selftest, a reader in `VitalsKernel`, and the
menu only wiring the two. Name the files and the selftests.

## E2E samples

What using it looks like: CLI output, a menu row, a sketch of the pure function.

```text
$ vitals <command>
```

## Out of scope

What this feature deliberately does not do, and who covers it instead.

## Open questions

Each with what would settle it.

## Verification

How the owner proves it works: selftests, a live run, a rendered preview
(`vitals sessions-preview`, `vitals placement-preview`), CI.
