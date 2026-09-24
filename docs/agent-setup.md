# Set up Vitals without previous chat context

Use this procedure for a new Mac, an empty registry, reinstalling, lost
configuration, or rebuilding local and remote credential monitoring. Finish each
step's check before treating that part as configured.

## 1. Find or install the app

Use an existing checkout when available; inspect its working tree before updating
it. The usual checkout is `~/Developer/vitals`. If absent:

```bash
mkdir -p ~/Developer
git clone https://github.com/ANcpLua/vitals.git ~/Developer/vitals
cd ~/Developer/vitals
```

The package requires macOS 13 or later and a Swift 6 toolchain. Check
`xcode-select -p`, `xcrun swift --version`, and `python3 --version`. Install missing
Command Line Tools through `xcode-select --install`. GitHub monitoring also needs
`gh`; installing remote workflows needs `actionlint`. Use the machine's existing
package manager for missing tools. These Python helpers use the standard library.
On ANcpLua's Mac use `~/.local/bin/pytools` when present; elsewhere use the Command
Line Tools Python. Leave any existing shared Python environment unchanged.

```bash
./install.sh
"$HOME/Applications/Vitals.app/Contents/MacOS/vitals" snapshot
launchctl print "gui/$(id -u)/dev.ancplua.vitals"
```

The installer builds and signs the app, installs the LaunchAgent, and registers
the bundled `fable-subagent-gate.sh` as a Claude `PreToolUse(Agent)` hook. It creates
`~/.claude` when absent and preserves unrelated settings and hooks. It leaves
credential files and registry configuration in place. With the lid closed and
Stay awake active, use the installer to restart; normal Quit clears the sleep override.

Done: the snapshot exits successfully and launchd reports Vitals running.

## 2. Recover or create the registry

Inspect `~/.config/vitals/keys.json` and `keys.last-good.json` before creating files.

| State | Action |
| --- | --- |
| Existing valid registry | Retain it; merge only missing entries from the template. |
| Registry absent or corrupt, valid recovery copy | Run `vitals keys restore` using the installed binary's full path if needed. |
| Both copies unusable | Preserve them and recover from a Mac backup. If no backup exists, rebuild configuration from the template after setting aside the damaged files. |
| Neither copy exists | Create the ANcpLua template below, or use `vitals keys init` for a generic two-entry example. |

[`../examples/keys.ancplua.json`](../examples/keys.ancplua.json) contains the ten
configured entries and all nine remote checks across five repositories. It contains
locations, provider names, repository names and non-secret resource IDs, without
credential values or historical success claims. Review its repository names and
resource IDs for the current account; it describes the ANcpLua setup as of
2026-09-24. The schema is [`../schema/keys.schema.json`](../schema/keys.schema.json).

For a completely empty configuration, run this from the checkout. Select the
Python interpreter described above in place of `python3` when appropriate:

```bash
python3 - <<'PY'
import json, os
from pathlib import Path
registry = json.loads(Path('examples/keys.ancplua.json').read_text())
registry.pop('$schema', None)  # The example's relative editor link is checkout-specific.
directory = Path.home() / '.config/vitals'
directory.mkdir(parents=True, exist_ok=True)
if (directory / 'keys.last-good.json').exists():
    raise SystemExit('Recovery copy exists: restore it instead.')
descriptor = os.open(directory / 'keys.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, 'w') as output:
    json.dump(registry, output, indent=2)
    output.write('\n')
PY
"$HOME/Applications/Vitals.app/Contents/MacOS/vitals" keys
```

The exclusive create refuses to overwrite an existing registry. The first
successful `keys` load saves the validated, owner-only recovery copy. Missing
credentials are expected on a new Mac; presence alone is not authentication.

Done: all intended entries appear, and `keys.last-good.json` contains the same
configuration. The template recreates the index, not the credentials.

## 3. Restore credentials or complete the provider's login

Keep values in Keychain, owner-only credential files, or GitHub Actions secrets.
Read or transfer them only as needed for the authorized setup/check; keep them out
of terminal output, command arguments, chat, Git and the registry. Local credential
files should have mode `0600`. The supported formats below come from
`local_environment()` in `Sources/VitalsKernel/credential_health.py`.

| Provider | Local location and format | Completion evidence |
| --- | --- | --- |
| Claude Code | Login through Claude Code; it maintains Keychain service `Claude Code-credentials`. | The app's existing usage poll succeeds. `keys check` does not add another Claude poll. |
| Chrome Web Store | `~/.config/vitals/cws-client.json` has `client_id` and `client_secret`, either at the root or under `installed`/`web`; `cws-refresh-token.txt` contains the refresh token. | Local OAuth and Web Store scope accepted; remote job confirms item access. |
| Microsoft Edge | `~/.config/vitals/store-secrets.env` defines `EDGE_API_KEY` and `EDGE_CLIENT_ID`. Local check options hold `EDGE_PRODUCT_ID` and an actual prior successful `EDGE_OPERATION_ID`. | Read-only GET of that publishing operation succeeds. A missing/expired operation or 404 is not proof of a bad credential; recover a real operation ID from the publishing workflow. |
| Firefox AMO, file | The same env file defines nonempty `AMO_JWT_ISSUER` and `AMO_JWT_SECRET`. Use literal `NAME=value` or `export NAME='value'` lines; shell expansion is not evaluated. | Signed profile request succeeds. An existing env file with empty assignments is insufficient. |
| Firefox AMO, Keychain | Service `AMO API (addons.mozilla.org)`: account is the JWT issuer, password is the JWT secret. | The separate Keychain profile request succeeds. Both this and the file entry must be checked. |
| qyl hosted MCP | Hosted MCP login supplies Keychain services `qyl-mcp-hosted-refresh` and `qyl-mcp-hosted-client-id`, both with account `qyl`. | Refresh exchange and authenticated `server/discover` succeed. |

The `auth0` adapter is specific to `qyl-eu.eu.auth0.com` and `mcp.qyl.at`; its
Keychain services and URLs are fixed in the helper. A different tenant requires an
adapter change, not just a registry rename. A rotated refresh token is saved before
the MCP request. Check the helper's default protocol revision against the deployed
server when diagnosing protocol errors; `MCP_PROTOCOL_VERSION` is an optional
non-secret local check option.

GitHub secret values cannot be downloaded through the secrets metadata API. If a
credential cannot be restored from its existing vault/Keychain backup, use the
provider's login or token-creation flow. Report the specific missing credential
and continue independent setup; never label an unconfigured provider healthy.

## 4. Connect remote monitoring

Check `gh auth status --hostname github.com`; if signed out, complete
`gh auth login --hostname github.com`. The Mac's `gh` login needs access to
repository secret metadata and Actions results. It is separate from the release
token being tested inside CI. GitHub-hosted jobs keep provider values in GitHub;
the Mac reads only names, update times and the dedicated job result.

The ANcpLua repository mapping and exact required secret names are in `REPOS` in
[`../scripts/install_health_workflows.py`](../scripts/install_health_workflows.py):

| Repositories | Provider job / required GitHub secrets |
| --- | --- |
| `ANcpLua/qyl.mcp` | `railway`: `RAILWAY_TOKEN` |
| `ANcpLua/Qyl.OpenTelemetry.AutoInstrumentation`, `ANcpLua/Qyl.OpenTelemetry.SemanticConventions` | `github`: `RELEASE_TOKEN` with repository write access |
| `ANcpLua/save-media`, `ANcpLua/yt-transcript` | `chrome`: `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`, `CWS_REFRESH_TOKEN`, `CWS_PUBLISHER_ID`; `amo`: `AMO_JWT_ISSUER`, `AMO_JWT_SECRET`; `edge`: `EDGE_API_KEY`, `EDGE_CLIENT_ID` |

For Railway, use a **project token** for qyl and production. Verify the expected
project/environment IDs in `REPOS` against Railway before creating a replacement.
Account CLI login and project-token authentication are different paths. Diagnose
billing separately from a token rejection. For the store repositories, verify
`store.config.json` has the Chrome/Edge product IDs and that the configured Edge
operation IDs still identify real operations.

List secret names with `gh secret list --repo OWNER/REPO`. For a needed replacement,
use `gh secret set SECRET_NAME --repo OWNER/REPO` with its secure prompt or protected
stdin. Retain existing secrets that already authenticate successfully.

If `.github/workflows/credential-health.yml` already exists and passes, retain it.
For new or changed monitoring, review the generator's repository mapping, then:

```bash
vitals_ref=$(git rev-parse HEAD)
python3 scripts/install_health_workflows.py --ref "$vitals_ref"
# After reviewing the generated configuration, for the authorized remote setup:
python3 scripts/install_health_workflows.py --ref "$vitals_ref" --apply
```

The ref must be a pushed, tested, immutable Vitals commit. The first invocation
only validates generated YAML with `actionlint`; `--apply` commits to all five
configured repositories. For other accounts, adapt both the generator's owner/
repositories and the registry; this script is deliberately specific to ANcpLua.

Each workflow runs every six hours, on a change to that workflow, and on manual
dispatch. To verify now, use `gh workflow run credential-health.yml --repo OWNER/REPO`,
then inspect that run. Done: each expected provider job has a successful
**Credential accepted** step. A listed secret, unrelated green build, skipped
probe, or older success followed by a failing run is insufficient.

## 5. Verify and hand off

Run the installed `vitals keys` for presence and remote evidence, then
`vitals keys check` for explicitly requested local authentication tests. In the
menu, use **Re-check now** and **Test local credentials**; hover each row for the
individual result, time and workflow link. Local Chrome scope-only success does
not establish item access. Claude's latest usage result is available in the menu.

Checks become stale after 24 hours; a remote secret updated after the run also
makes that result stale. Treat unavailable/rate-limited results as unknown rather
than authenticated. Use existing usage polling for Claude, without repeated CLI
polls. Entries must remain visible while slow checks run.

Done: the app runs, the intended registry is backed up, every configured check has
current success evidence or an explicitly reported missing prerequisite/failure,
and remote monitoring is scheduled. Report unresolved results individually; do not
claim everything is authenticated when only file or secret presence was checked.

Code/schema/template recovery comes from GitHub. Registry recovery uses the saved
copy or the metadata-only template. Credential recovery needs Keychain/file backups
or a new provider login. The disposable `key-health.json` cache can be rebuilt.
Deleting the whole `.config/vitals` directory removes both registry copies, so
include it and the credential sources in the Mac's normal backup plan.
