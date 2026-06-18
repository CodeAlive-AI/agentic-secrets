# Agentic Secrets

Agentic Secrets protects runtime secrets on macOS developer machines.

It keeps long-lived provider tokens out of ambient places like `.env` files, shell startup files, MCP configs, and native CLI config files. Secrets are stored locally, released only for an approved runtime request, and tied to a specific tool, target binary identity, delivery context, and local authentication event.

Agentic Secrets does not sandbox commands or make target tools trustworthy. It protects the secret delivery boundary: when a secret may be released, to which local tool, through which mechanism, under which policy, and with what audit trail.

## Why

Developer tools often expect credentials to be present before they run. That pushes secrets into broad, sticky locations:

- shell environments inherited by unrelated processes
- `.env` files and shell rc files
- MCP server configuration files
- native CLI config files
- ad hoc scripts and logs

Agentic Secrets replaces ambient secret presence with explicit runtime delivery.

## How It Works

- Register a local tool and the secret bindings it may receive.
- Store secret material in an owner-only encrypted local store.
- Validate the target binary identity before each delivery.
- Require macOS LocalAuthentication before secret release.
- Reuse narrowly scoped delivery grants only when policy allows.
- Fail closed on registry, policy, grant, or target identity tampering.
- Write structured audit records without secret values.

## Install

Requirements: macOS Tahoe 26.x, SwiftPM, and Xcode Command Line Tools or Xcode with the macOS 26 SDK.

```sh
git clone https://github.com/CodeAlive-AI/agentic-secrets.git
cd agentic-secrets
./scripts/install_local.sh --load --configure-shell
```

Open a new terminal, then verify:

```sh
command -v agentic-secrets
agentic-secrets release-gates
```

## Documentation

- [Installation](Docs/INSTALLATION.md)
- [Operations](Docs/OPERATIONS.md)
- [Threat model](Docs/THREAT_MODEL.md)
- [Acceptance criteria](Docs/ACCEPTANCE_CRITERIA.md)
- [Implementation map](Docs/IMPLEMENTATION_MAP.md)
- [Ubiquitous language](Docs/THESAURUS.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
