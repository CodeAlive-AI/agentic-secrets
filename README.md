# AgenticFortress

Version: `0.1.0 alpha`

AgenticFortress is a macOS self-build tool for lower-leakage secret delivery on developer machines.

It keeps provider tokens out of `.env` files, shell startup files, MCP configs, and native CLI config files such as `hcloud`'s `cli.toml`. It does not make arbitrary command execution safe; it makes secret delivery explicit, narrow, locally approved, auditable, and fail-closed.

This is an alpha release: expect breaking changes while the CLI, storage format, and trust model settle.

## How It Works

- You register a CLI app once, for example `hcloud`, and pass the token through stdin.
- AgenticFortress stores the secret in a local encrypted store and keeps non-secret CLI metadata in its registry.
- Each run validates the registered target binary identity before resolving the secret.
- macOS LocalAuthentication is required before secret delivery. Depending on system state, macOS may ask for Touch ID, Apple Watch, or the local account password.
- Successful CLI authentication creates a short scoped unlock grant for matching runs. The default TTL is 5 minutes and is bound to the CLI, target identity, workspace, parent app, delivery mode, and secret alias. Each command is still policy-checked before secret delivery.
- Trust changes, such as `trust-refresh` after a CLI upgrade, also require LocalAuthentication.
- Registry tampering and target replacement fail closed before any secret is read.

## Quick Install

Requirements: macOS Tahoe 26.x, SwiftPM, Xcode Command Line Tools or Xcode with the macOS 26 SDK.

```sh
git clone https://github.com/<owner>/agentic-fortress.git
cd agentic-fortress
./scripts/install_local.sh --load --configure-shell
```

Open a new terminal, or load the PATH change in the current one:

```sh
source "$HOME/.zshrc"
command -v agentic-fortress
```

Verify the local build:

```sh
agentic-fortress release-gates
```

## hcloud Example

Register `hcloud` without writing the token to `cli.toml`:

```sh
agentic-fortress cli register hcloud \
  --env HCLOUD_TOKEN \
  --secret-prompt
```

Run `hcloud` through AgenticFortress:

```sh
agentic-fortress cli run hcloud -- server list
```

Disable the short unlock window for one run:

```sh
agentic-fortress cli run hcloud --unlock-ttl-seconds 0 -- server list
```

Optional: install a shim so `hcloud ...` itself routes through AgenticFortress. This does not replace the Homebrew binary; it creates an AgenticFortress shim directory that is placed before the native CLI on `PATH`.

```sh
agentic-fortress cli shim install hcloud --configure-shell
```

Open a new terminal, then use:

```sh
hcloud server list
hcloud version
```

Normal commands go through AgenticFortress secret delivery. Global help/version commands pass through without secret delivery.

After a Homebrew upgrade of `hcloud`, verify the new binary and refresh trust:

```sh
agentic-fortress cli trust-refresh hcloud
```

### Codex App

Codex App may not inherit the same shell startup environment as Terminal. Do not
put `HCLOUD_TOKEN` into `~/.codex/.env`; that bypasses AgenticFortress secret
delivery. Instead, install the AgenticFortress shim and make sure Codex resolves
`hcloud` to the local shim path:

```sh
agentic-fortress cli shim install hcloud --force
command -v hcloud
```

Expected path:

```text
~/Library/Application Support/AgenticFortress/LocalInstall/shims/hcloud
```

## More

- Full install and troubleshooting: [Docs/INSTALLATION.md](Docs/INSTALLATION.md)
- Operations guide: [Docs/OPERATIONS.md](Docs/OPERATIONS.md)
- Acceptance criteria: [Docs/ACCEPTANCE_CRITERIA.md](Docs/ACCEPTANCE_CRITERIA.md)
- Threat model: [Docs/THREAT_MODEL.md](Docs/THREAT_MODEL.md)
- Developer/agent notes: [AGENTS.md](AGENTS.md)
