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

The installer builds and signs the app and installs the LaunchAgent. It links the CLI
as `~/.local/bin/vitals` and installs the `vitals-keys` skill into
`~/.claude/skills`. It leaves the registry (step 2) and the credential files in
place. With the lid closed and Stay awake active, use the installer to restart;
normal Quit clears the sleep override.

Done: the snapshot exits successfully and launchd reports Vitals running.

## 2. Recover or create the registry

The registry `~/.config/vitals/keys.json` lives only on the Mac. It names accounts,
projects, repositories and where every credential is kept, and this repository is
public, so nothing copies it here and no entry of it belongs in a commit.

| State | Your action |
| --- | --- |
| Valid registry | None. |
| Neither registry nor recovery copy exists | Restore `~/.config/vitals` from the Mac's backup if there is one. Otherwise run `vitals keys init`: it writes the Claude Code entry and one example entry; keep the first, replace the second, and add the rest. |
| Registry absent or corrupt, valid recovery copy | Run `vitals keys restore`. |
| Both copies unusable | Preserve them and recover from a Mac backup. If no backup exists, set the damaged files aside and run `vitals keys init`. |

Agents edit the registry following the `vitals-keys` skill. The schema is
[`../schema/keys.schema.json`](../schema/keys.schema.json), and
[`../examples/keys.example.json`](../examples/keys.example.json) shows one made-up
entry of each kind. To remove an entry, delete it from the registry.

The first successful `keys` load saves the validated, owner-only recovery copy.
Missing credentials are expected on a new Mac; presence alone is not authentication.

Done: `vitals keys` lists the entries this Mac needs. The registry is the index, not
the credentials.

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
| Hosted MCP server behind Auth0 | Two Keychain items hold the refresh token and the client id of a hosted MCP login. The entry's local check options name them and the endpoints: `AUTH0_DOMAIN`, `MCP_URL`, `MCP_REFRESH_SERVICE`, `MCP_CLIENT_ID_SERVICE` and `MCP_KEYCHAIN_ACCOUNT`. | Refresh exchange and authenticated `server/discover` succeed. |

The `auth0` check asks nothing until its options are complete, because a rotated
refresh token is saved to the named Keychain item before the MCP request and would
otherwise be lost. Check the helper's default protocol revision against the deployed
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

Which repository gets which provider job is part of the registry: the
`remoteChecks` of an entry. There is no second file. Entries that name the same
repository and job count as one job.

| Field of a remote check | Meaning |
| --- | --- |
| `repository` | The monitored repository, as `owner/name`. |
| `job` | `railway`, `github`, `chrome`, `amo` or `edge`. |
| `secrets` | The GitHub Actions secret names the job reads: `RAILWAY_TOKEN`; `RELEASE_TOKEN` with repository write access; `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`, `CWS_REFRESH_TOKEN`, `CWS_PUBLISHER_ID`; `AMO_JWT_ISSUER`, `AMO_JWT_SECRET`; `EDGE_API_KEY`, `EDGE_CLIENT_ID`. |
| `workflow` | `credential-health.yml`. A check that names another workflow is read for its results but is not generated. |
| `variables` | Non-secret values written into the workflow: `RAILWAY_PROJECT_ID` and `RAILWAY_ENVIRONMENT_ID` for `railway`, `EDGE_OPERATION_ID` for `edge`. A value kept as a repository secret is listed under `secrets` instead. |

The script refuses a job that lacks what its probe needs, and a job that sets a name
the workflow fills in itself (`CHECK_REPOSITORY`, `CWS_ITEM_ID`, `EDGE_PRODUCT_ID`).
Two spellings of a repository that differ in case are one repository. Secrets and
variables are written in name order, so the order of entries in the registry does
not change a workflow.

The menu bar app rewrites the registry every hour from the fields it knows. Install
the build that knows a field (`./install.sh`) before writing that field: an older
build drops it at its next rewrite, from `keys.json` and from `keys.last-good.json`.

For Railway, use a **project token** for the project and environment the entry names,
and verify those ids against Railway before creating a replacement. Account CLI
login and project-token authentication are different paths. Diagnose billing
separately from a token rejection. For store repositories, verify
`store.config.json` has the Chrome/Edge product IDs and that the configured Edge
operation IDs still identify real operations.

List secret names with `gh secret list --repo OWNER/REPO`. For a needed replacement,
use `gh secret set SECRET_NAME --repo OWNER/REPO` with its secure prompt or protected
stdin. Retain existing secrets that already authenticate successfully.

For new or changed monitoring, review the entries' remote checks, then:

```bash
vitals_ref=$(git rev-parse HEAD)
python3 scripts/install_health_workflows.py --ref "$vitals_ref"
# After reviewing the generated configuration, for the authorized remote setup:
python3 scripts/install_health_workflows.py --ref "$vitals_ref" --apply
```

The ref must be a pushed, tested, immutable Vitals commit. The first invocation
only validates generated YAML with `actionlint`. `--apply` commits to each
repository that has a `credential-health.yml` remote check and whose workflow file
differs from the generated one, and prints `already current` for the others. The
file belongs to the script: a hand-edited `credential-health.yml` is replaced. The
commit carries the account's handle and its GitHub no-reply address, not the
profile name or email. `--registry PATH` reads another file.

Every workflow checks out Vitals at that ref. If the history of the Vitals
repository is rewritten, that commit can disappear, and each monitored workflow
then fails at its checkout step: run the script again with a ref that exists.

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

Code and schema recovery comes from GitHub. Registry recovery uses the saved copy
or the Mac's backup; the repository no longer carries a copy. Credential recovery
needs Keychain/file backups or a new provider login. The disposable `key-health.json` cache can be rebuilt.
Deleting the whole `.config/vitals` directory removes both registry copies, so
include it and the credential sources in the Mac's normal backup plan.
