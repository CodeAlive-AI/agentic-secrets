# AgenticFortress Operations

## Verification

The full no-Developer-ID production acceptance set is defined in `Docs/ACCEPTANCE_CRITERIA.md`.

Run the standard contract gate:

```sh
./scripts/ci.sh
```

Run the macOS Tahoe package/signing gate:

```sh
./scripts/tahoe_compatibility_check.sh
```

## Adapter Management

List built-in adapter metadata:

```sh
swift run agentic-fortress adapter list
```

Install a verified payload into a registry document:

```sh
swift run agentic-fortress adapter install-payload payload.json state/adapters.json
```

Revoke an adapter:

```sh
swift run agentic-fortress adapter revoke com.example.adapter state/adapters.json
```

External adapter packs must be signed and verified before they are accepted by production policy. Adapter id, version, and hash are part of remembered lease scope.

## Policy Recovery

Rollback mismatch puts policy into locked mode. Allowed operator actions:

- export diagnostic summary
- reset local policy
- import recovery bundle
- rebind providers

Blocked actions:

- secret delivery
- remembered approvals
- provider leases
- MCP bridge sessions

Accepting an old policy database never preserves remembered approvals.

## BWS Rotation

Rotation order:

1. create new BWS token
2. store new token in Keychain under `agentic-fortress-bwsd`
3. test exact approved secret access
4. switch binding
5. invalidate provider leases
6. revoke old token
7. write redacted audit event

Production BWS profiles require per-fetch approval by default.

## Proxy Profiles

Proxy profiles must define:

- upstream origin
- allowed path prefixes
- allowed methods
- secret alias
- token TTL

Request and response bodies are not logged by default.

## MCP Profiles

MCP bridge profiles must define:

- pinned upstream origin
- allowed path prefixes
- Authorization header behavior
- cross-origin redirect policy

The bridge propagates `MCP-Session-Id` when supplied by the upstream server. Tool filtering is only a guardrail; upstream authorization scope remains the real security boundary.

## Release

Local package validation:

```sh
./scripts/package_release.sh
./scripts/validate_release_artifact.sh build/AgenticFortress.app
```

The default supported distribution path is source checkout plus local ad-hoc signing. Developer ID signing and notarization are optional future maintainer steps for downloadable binaries.

Optional distribution signing and notarization:

```sh
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARYTOOL_PROFILE="agentic-fortress-notary" \
./scripts/sign_notarize_release.sh
```

Credentials must be stored in the macOS keychain via `xcrun notarytool store-credentials`. Do not put signing or notarization secrets in repository files.

See `Docs/FUTURE_DEVELOPER_ID.md` for the optional Developer ID roadmap.
