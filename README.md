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

The current package includes packaging/signing scaffolding, but production deployment still needs real Developer ID signing, notarization credentials, XPC listener wiring, hardened runtime validation, and Keychain access-control prompts.

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

Set `CODESIGN_IDENTITY` to sign with a Developer ID identity. Without it, the script ad-hoc signs for local validation only.
