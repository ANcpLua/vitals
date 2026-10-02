---
name: vitals-keys
description: Vitals credential registry. Use when a key, token, secret, license or environment variable is created, received, set on a platform (Railway variable, GitHub secret), moved, renamed, replaced, or found missing or exposed.
---

Vitals is the index of where every credential lives: `~/.config/vitals/keys.json`, printed by `vitals keys`. It holds names, locations and notes; the values stay in their files, Keychain items and platforms. One credential has one entry, and every agent takes its location and variable name from that entry.

1. **Look first.** Run `vitals keys`. Done when you know whether the credential is registered. If it is, use its location and the variable name in its note.
2. **Register** a new or changed credential by editing `keys.json` with the shapes below. Done when `vitals keys` lists the entry as `present`, or as `unchecked` for a reference.

## Entry shapes

Every entry has `name`, `kind` and a `note`. The note starts with the variable name agents must use, `Use as RESEND_API_KEY.`, then lists every other place the same value is set, so a replacement reaches all of them. `url` is where the key is created or revoked.

- `"kind": "file", "path": …` is a value held on this Mac. Keep it as an owner-only file in `~/.config/vitals/`, written from stdin so the value stays out of command lines and chat.
- `"kind": "keychain", "service": …, "account": …` is a Keychain item.
- `"kind": "environment", "variable": …` is exported in the zsh rc files.
- `"kind": "reference", "reference": …` is a place Vitals cannot check: variables on a platform, a GitHub Actions secret. Name the platform, project, service and environment. Point the note at the repo file that declares the variable names.

Replace a key only when its value has been seen in a public place. A value that appeared in a file, a private repo or a chat stays in use.

Monitoring fields (`remoteChecks`, `localCheck`) and recovery: `docs/agent-setup.md` in github.com/ANcpLua/vitals.

## Variable names

A variable name has one owner: the code that reads it. Platform config (`.railway/railway.ts`, workflow files) and `.env.example` follow that name, and example files carry placeholders. Rename the reader, every follower and the Vitals note in one change.
