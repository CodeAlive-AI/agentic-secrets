# AgenticFortress Threat Model

AgenticFortress is a macOS lower-leakage secret delivery system for developer machines.

It does not make arbitrary execution safe. It narrows how secrets are delivered, records why delivery was allowed, and prevents common plaintext leakage paths such as `.env`, shell profiles, shell history, inherited shell environment, MCP client configs, and provider tokens in process argv.

## Security Claims

- Secret access is tied to an explicit delivery intent.
- There is no public `getSecret(name)` API.
- Invocation handles are opaque, server-side, short-lived, single-use, and context-bound.
- Generic runners do not receive raw long-lived secrets by default.
- Adapter packs are signed, versioned, hash-bound, and rollback-checked before becoming trusted classification logic.
- Audit and debug paths reject raw secret-shaped values.
- Rollback detection locks policy use and clears remembered leases.
- Proxy and MCP paths pin profiles and block cross-origin redirects by default.
- Self-build IPC authorization uses an install manifest with resolved helper paths, owner user id, permissions, minimum version, SHA-256 hash, and optional cdhash. Developer ID Team ID checks are optional for future binary distribution, not required for source builds.
- Keychain reads are device-local, user-presence bound, and use LocalAuthentication reasons derived from the full decision manifest.

## Non-Claims

- AgenticFortress does not make approved target binaries trustworthy.
- AgenticFortress does not defend against root or kernel compromise.
- AgenticFortress only partially reduces risk from same-user malware.
- Local proxy tokens and MCP bridge sessions are local bearer capabilities.
- Tool filtering is a UX guardrail, not a security boundary.
- Remote delivery cannot guarantee that a remote command does not log or persist a secret.

## Trusted Computing Base

- `agentic-fortressd-core`: policy, approvals, invocation handles, audit, rollback decisions.
- `agentic-fortress-shim`: symlink-invoked delivery sink and exec planner.
- `agentic-fortress-bwsd`: BWS token owner and one-secret provider helper.
- `agentic-fortress-proxyd`: profile-pinned local API proxy.
- `agentic-fortress-mcpd`: stdio to Streamable HTTP MCP credential bridge.
- macOS Keychain and LocalAuthentication for production secret unlock and user presence.
- Signed adapter packs that classify commands.

## Primary Attack Surfaces

- Malicious or compromised target CLI.
- Command adapter supply chain.
- Ambient environment contamination.
- Policy database rollback.
- Audit/debug logging.
- Localhost proxy abuse.
- MCP upstream changes or deceptive tools.
- Provider helper compromise during active leases.
- macOS packaging/signing drift.

## Controls

- Adapter pack verification: P-256 signature, trusted key id, publisher allowlist, CLI allowlist, expiry, schema version, rule validation, rollback rejection.
- Decision manifests: deterministic digest, action class, target identity, secret alias, workspace hash, warnings, and bounded approval options.
- Approval sessions: digest-bound, action-bound, policy-epoch-bound, and expiring.
- Environment scrubber: removes known and secret-shaped inherited variables before injection.
- Target assessment: hashes target binary and rejects world-writable parent directories.
- Policy repository: MAC-protected envelope and plaintext-secret rejection.
- Rollback anchor model: epoch/hash mismatch locks policy and clears remembered leases.
- Proxy runtime: local token, method/path allowlist, upstream origin pinning, no body logging.
- MCP bridge: Authorization injection, session-id propagation, profile pinning, no body logging.
- Release gates: contract tests, Tahoe SDK/runtime gate, code signing verification, entitlement diff.
- Local install manifest: helper path, owner, permissions, version, binary hash, and cdhash validation without Developer ID.
- IPC protocol: versioned structured messages; unknown versions and helper identity mismatches fail closed.

## Residual Risk

The largest residual risks are trust in approved recipients, same-user local abuse while a delivery session is active, and the absence of Developer ID/notarization for downloadable binary convenience releases. These are tracked as explicit product non-claims, not hidden implementation details. The default source self-build track relies on local ad-hoc signing plus install-manifest identity binding instead of Apple Team ID identity.
