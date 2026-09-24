# Vitals agent entry point

Read [CLAUDE.md](CLAUDE.md) for repository commands, architecture, and change rules.

For a new Mac, an empty registry, reinstalling, restoring lost configuration, or
setting up credential monitoring, follow [docs/agent-setup.md](docs/agent-setup.md).
It includes the ANcpLua registry template, local credential locations, remote
workflow setup, recovery branches, and checks that establish completion.

Keep that guide and [schema/keys.schema.json](schema/keys.schema.json) aligned when
changing setup, registry storage, or provider checks. Keep credential values in
their existing Keychain, credential files, or GitHub secrets; repository examples
contain locations and configuration only.
