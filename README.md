# AgenticFortress

AgenticFortress is a macOS lower-leakage secret delivery system for developer machines.

It does not make execution safe. It makes delivery of secrets explicit, narrow, approved, bounded, auditable, and lower-leakage than `.env`, shell environment, MCP configs, or plaintext provider tokens.

Implemented delivery contracts:

- Signed shim model through one `agentic-fortress-shim` binary and symlink-style invocation.
- CLI env delivery with signed/versioned dynamic command adapter packs and deterministic decision manifests.
- Local API proxy profiles with per-session localhost capability tokens.
- BWS provider split where runtime fetch is one approved secret per invocation.
- Remote MCP bridge contracts with pinned upstream profile and session propagation.
- Rollback detection that locks policy use and clears remembered leases.
- Structured audit with redaction gates.
- Release gate checklist backed by executable contract tests.

Adapter packs are dynamic but not trust-by-configuration. External packs must verify under a trusted P-256 signing key, publisher allowlist, CLI allowlist, schema version, expiry, rule validation, and rollback checks before registration. Lease scope includes adapter identity, version, and hash.

Runtime policy is configurable through `AgenticFortressConfig`; the default JSON lives at `config/default.agentic-fortress.json`. Configuration covers adapter trust, delivery defaults, proxy profiles, MCP profiles, and macOS compatibility gates.

The default distribution model is open-source self-build with local ad-hoc signing. Downloadable Developer ID-signed and notarized binaries are an optional future maintainer channel, not a requirement for contributors or local use.

See:

- `Docs/THREAT_MODEL.md`
- `Docs/ACCEPTANCE_CRITERIA.md`
- `Docs/OPERATIONS.md`
- `Docs/IMPLEMENTATION_MAP.md`
- `Docs/IMPLEMENTATION_PLAN.md`
- `Docs/FUTURE_DEVELOPER_ID.md`
- `Docs/THIRD_PARTY_NOTICES.md`

## Build

```sh
swift build
./scripts/ci.sh
./scripts/tahoe_compatibility_check.sh
```

## Package

```sh
./scripts/package_release.sh
```

By default, the package script ad-hoc signs for local validation and self-build installs.

## Install

```sh
./scripts/install_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall"
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall" --keep-secrets
```

The local installer writes an install manifest with helper paths, owners, permissions, versions, SHA-256 hashes, and cdhash values. Runtime IPC authorization uses that manifest instead of requiring a Developer ID Team ID.

The core daemon serves the local control plane over a Unix domain socket. Helpers authenticate to core with the install manifest and do not read Keychain secret material directly.

On macOS Tahoe, the self-build track avoids restricted entitlements so ad-hoc signed binaries can execute normally. The core daemon stores local secret material in an owner-only encrypted file store gated by LocalAuthentication; no shared Keychain access group is required for the self-build track.

## Release Evidence

```sh
swift run agentic-fortress release-gates
swift run agentic-fortress ipc-conformance
./scripts/check_secret_authority.sh
./scripts/check_entitlements_diff.sh build/AgenticFortress.app
./scripts/create_release_evidence.sh
```

`release-gates` reports `canRunLocal` separately from optional `canDistributeBinary`.

Optional future maintainer distribution signing and notarization:

```sh
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARYTOOL_PROFILE="agentic-fortress-notary" \
./scripts/sign_notarize_release.sh
```

The notarization script requires credentials to be stored in the macOS keychain via `xcrun notarytool store-credentials`; it never reads or prints credential values.
