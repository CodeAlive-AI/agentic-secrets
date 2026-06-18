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
- Local secret reads are device-local, user-presence bound, and use LocalAuthentication reasons derived from the full decision manifest.
- Repeated CLI invocations may reuse HMAC-signed authorization grants scoped to CLI name, target identity, workspace hash, config context, untrusted origin hint, provenance confidence, delivery mode, and secret alias. Persistent grant signatures use a device-local macOS Keychain key; short grants additionally bind action class, command digest, and risk. Grants contain no secret material. Command policy is still evaluated per invocation before any secret delivery, and destructive commands require fresh approval.

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
- Core-owned local encrypted secret store and LocalAuthentication for production self-build secret unlock and user presence. Optional future Keychain-backed storage is tracked separately for provisioned signing.
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
- Parser isolation: complex untrusted raw protocol parsers stay outside the secret authority path. Management IPC remains typed Codable JSON; future adapter, MCP, SSH-like, or provider-specific binary/body parsers must run in a helper/XPC-style process boundary and return narrow typed results to core.

## STRIDE Review

| Boundary | STRIDE category | Mitigation | Evidence / owner |
| --- | --- | --- | --- |
| Helper to core IPC | Spoofing | Self-build helper identity is authenticated by install manifest, resolved path, owner, permissions, minimum version, binary SHA-256, and optional cdhash. Developer ID Team ID is optional future evidence, not required for local source builds. | `SelfBuildPeerValidator`, `CoreIPCAuthorizer`, Unix socket contract tests. Owner: core runtime. |
| Helper to core IPC | Tampering | IPC messages are Codable, versioned, length-prefixed, and rejected on malformed payloads or unsupported protocol versions. | `CoreIPCCodec`, `UnixDomainSocketIPCClient`, `UnixDomainSocketIPCServer`, contract tests. Owner: core runtime. |
| Raw protocol parsing | Tampering | Complex parsers for untrusted adapter/MCP/provider/raw byte streams are isolated from core secret authority. Core accepts only bounded, typed results and fails closed on parser errors. | Parser-boundary acceptance criteria, fixed malformed fixtures, and architecture review before adding new raw parsers. Owner: parser subsystem. |
| Helper to core IPC | Repudiation | Approved and denied delivery decisions produce audit events with decision digest, action class, target identity, workspace hash, policy epoch, approval option, and outcome. | `AuditEvent.delivery`, `ShimExecutionPlanner` audit tests. Owner: audit subsystem. |
| Local secret resolution | Information Disclosure | Only core-owned code may use production local secret stores; helper and CLI targets are statically blocked from production secret read paths. Self-build secret records use owner-only encrypted files and LocalAuthentication user-presence gating without restricted entitlements. | `scripts/check_secret_authority.sh`, `LocalEncryptedSecretStore` tests. Owner: core runtime. |
| CLI authorization grants | Elevation of Privilege | Authorization grants are HMAC-signed, scope-bound, and store no secret material. Persistent grants can be `always` or `remember-24h` and are signed with a device-local macOS Keychain key; short grants are action-bound. Tampering with expiry or scope invalidates the grant; non-matching target/workspace/origin/config/secret prompts again, while command policy is re-evaluated for every invocation and destructive commands require fresh approval. | `CLIUnlockGrantStore`, `CLIPersistentAllowGrantStore` contract tests. Owner: core runtime. |
| Shim environment delivery | Information Disclosure | Parent secret-shaped environment variables are scrubbed, target env collisions fail closed, and generic runners are denied raw env delivery by default. | `EnvironmentScrubber`, `ShimExecutionPlanner`, contract tests. Owner: shim/core boundary. |
| Shim environment delivery | Elevation of Privilege | Symlink/argv invocation name is untrusted; target path and identity are resolved from policy and target assessment before exec planning. Registered CLI targets are pinned to the captured macOS designated requirement when available, with SHA-256 identity fallback for ad-hoc or unsigned tools, and target identity changes fail closed before secret resolution. | `TargetAssessor`, `CLIRegistrationService`, `ShimExecutionPlanner`, contract tests. Owner: shim/core boundary. |
| Registered CLI trust database | Tampering | `cli-registry.json` is owner-only and paired with a Keychain-keyed HMAC-SHA256 integrity sidecar. Register, unregister, and trust-refresh re-seal the sidecar; run fails closed before local authentication or secret resolution if either file is missing or modified outside AgenticFortress. Trust refresh requires LocalAuthentication and re-checks the target after authorization before writing new trust metadata. | `CLIRegistrationStore`, `KeychainCLIRegistryIntegrityProtector`, contract tamper and trust-refresh tests. Owner: core runtime. |
| Policy repository | Tampering | Policy state is stored in a MACed envelope; hand edits and plaintext-secret-shaped policy content are rejected. | `FilePolicyRepository` tests. Owner: policy subsystem. |
| Policy repository | Repudiation | Rollback anchor mismatch locks policy and clears remembered leases rather than silently accepting stale approvals. | `RollbackProtector`, recovery bundle tests. Owner: policy subsystem. |
| Adapter registry | Tampering | External adapter packs are signed declarative data. Registration enforces trusted key id, publisher allowlist, CLI allowlist, schema version, expiry, rule validation, golden fixtures, and rollback checks. | `AdapterPackVerifier`, `AdapterRegistry`, contract tests. Owner: adapter subsystem. |
| BWS provider path | Information Disclosure | Runtime fetch is scoped to exactly one approved alias and sink. List and project-wide runtime operations are unavailable. | `BWSProviderPolicy`, `BWSProviderRuntime`, contract tests. Owner: provider subsystem. |
| BWS provider path | Denial of Service | Provider leases are short-lived by environment and prod requires per-fetch approval. Rotation has an ordered workflow that includes lease invalidation. | `BWSProviderLeasePolicy`, `BWSRotationWorkflow`, contract tests. Owner: provider subsystem. |
| Local API proxy | Spoofing | Proxy requests require a localhost session capability token bound to profile, port, and TTL. | `ProxyAuthorizer` tests. Owner: proxy subsystem. |
| Local API proxy | Tampering | Upstream origin, method, and path prefixes are pinned; cross-origin redirects are denied. | `ProxyRuntime`, redirect tests. Owner: proxy subsystem. |
| Local API proxy | Information Disclosure | Request and response bodies are not logged by default; authorization metadata is redacted. | `ProxyRuntime.bodyForAudit`, audit metadata tests. Owner: proxy subsystem. |
| MCP bridge | Spoofing | Authorization injection is only produced through a pinned upstream profile and allowed path validation. | `MCPBridgeSession.prepareHTTPRequest`, contract tests. Owner: MCP subsystem. |
| MCP bridge | Tampering | Invalid JSON-RPC, cancellation markers, 401 metadata, 404 reset metadata, and cross-origin redirects are handled explicitly. | `JSONRPCFramer`, `MCPBridgeSession` tests. Owner: MCP subsystem. |
| MCP bridge | Information Disclosure | Bearer tokens are injected only into upstream requests and are represented as redacted metadata in audit paths. Bodies are not logged. | MCP bridge contract tests. Owner: MCP subsystem. |
| Local install/update/uninstall | Elevation of Privilege | Install is user-local by default, uses ad-hoc signing validation, writes an install manifest, and does not require weakening macOS security settings. | `scripts/install_local.sh`, `scripts/uninstall_local.sh`, Tahoe gate. Owner: packaging subsystem. |
| Local install/update/uninstall | Denial of Service | Uninstall removes launch agents, sockets, shims, run files, and app files; local state purge is explicit and local secret records are not deleted implicitly. | install/uninstall smoke tests. Owner: packaging subsystem. |

No high-severity STRIDE finding is currently unowned. Residual high-impact limits are recorded below as accepted non-goals for the no-Developer-ID self-build track.

## Residual Risk

The largest residual risks are trust in approved recipients, same-user local abuse while a delivery session is active, and the absence of Developer ID/notarization for downloadable binary convenience releases. These are tracked as explicit product non-claims, not hidden implementation details. The default source self-build track relies on local ad-hoc signing plus install-manifest identity binding instead of Apple Team ID identity.
