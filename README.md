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

The current package includes packaging/signing scaffolding and runnable contract gates. Production distribution is intentionally blocked by release gates until real Developer ID signing, notarization credentials, XPC listener wiring, hardened runtime validation, and end-to-end Keychain access-control prompts are proven.

See:

- `Docs/THREAT_MODEL.md`
- `Docs/OPERATIONS.md`
- `Docs/IMPLEMENTATION_MAP.md`
- `Docs/IMPLEMENTATION_PLAN.md`
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

Set `CODESIGN_IDENTITY` to sign with a Developer ID identity. Without it, the script ad-hoc signs for local validation only.

Distribution signing and notarization:

```sh
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARYTOOL_PROFILE="agentic-fortress-notary" \
./scripts/sign_notarize_release.sh
```

The notarization script requires credentials to be stored in the macOS keychain via `xcrun notarytool store-credentials`; it never reads or prints credential values.
