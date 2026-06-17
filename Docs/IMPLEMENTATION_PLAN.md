# AgenticFortress Production Implementation Plan

This plan turns the current production-contract skeleton into a production macOS security product. Every step must end with verification and a commit. The production-ready definition for the default no-Developer-ID track is governed by `Docs/ACCEPTANCE_CRITERIA.md`.

## Current Status

The no-Developer-ID production track is implemented as source self-build plus local ad-hoc signing:

- `swift run agentic-fortress release-gates` reports `canRunLocal` for the default release track and `canDistributeBinary` only for optional future Developer ID distribution.
- `swift run agentic-fortress ipc-conformance` reports the versioned local IPC control plane and helper authorization model.
- `./scripts/install_local.sh` and `./scripts/uninstall_local.sh` cover local install, update-by-reinstall, uninstall, launch-agent cleanup, symlink cleanup, and explicit local-state purge.
- `./scripts/interactive_keychain_prompt_check.sh` covers non-interactive contracts by default and a real prompt-producing LocalAuthentication/local-secret smoke check when `AGENTIC_FORTRESS_INTERACTIVE=1`. The script name is retained for compatibility with earlier acceptance scripts.
- `./scripts/create_release_evidence.sh` generates release evidence with commit, OS, SDK, Swift version, gate output, package validation, and residual risks.

## Step 1: Local Secret Store and Approval Session Core

Scope:

- Add a protocol-driven local secret store abstraction.
- Add an in-memory development implementation for tests.
- Add a Keychain-backed implementation placeholder with explicit Touch ID/LocalAuthentication boundaries.
- Add approval sessions that bind manifest digest, action class, approval option, expiry, and policy epoch.

Verification:

- Contract tests cover successful secret binding, missing secret denial, approval expiry, digest mismatch, policy epoch mismatch, and no raw secret in audit/export.
- `./scripts/ci.sh`

Commit:

- `Implement local secret store and approval sessions`

## Step 2: Persistent Policy Database and Rollback Anchor

Scope:

- Add a policy repository abstraction.
- Add encrypted/MACed file format scaffolding with explicit no-plaintext-secret invariant.
- Persist policy epoch/hash and remembered leases.
- Persist or simulate rollback anchor state without storing provider secrets in plaintext.
- Add recovery bundle export/import model without provider token plaintext.

Verification:

- Contract tests cover lease persistence, rollback lock, remembered lease clearing, recovery bundle no-token invariant, and stale policy rejection.
- `./scripts/ci.sh`

Commit:

- `Implement persistent policy database contracts`

## Step 3: Adapter Pack Lifecycle Commands

Scope:

- Add CLI commands for adapter `list`, `verify`, `install`, and `revoke`.
- Persist adapter registry metadata.
- Add golden classification fixture support.
- Make adapter changes visible as policy/lease invalidators.

Verification:

- Contract tests cover install, revoke, invalid signature, rollback, golden fixture pass/fail, and lease invalidation after adapter hash change.
- `./scripts/ci.sh`

Commit:

- `Implement adapter pack lifecycle`

## Step 4: Real Shim Request and Exec Preparation

Scope:

- Add request model for shim -> core authorization.
- Resolve symlink invocation name as untrusted input.
- Resolve target path through policy, not argv alone.
- Build fresh scrubbed environment.
- Prepare an exec plan that contains target path, argv, env, target assessment, and invocation handle.
- Keep actual `execve` behind a small boundary so tests do not launch arbitrary tools.

Verification:

- Contract tests cover symlink-name spoofing, env collision denial, secret-like env scrubbing, generic runner raw env denial, target hash binding, and handle replay denial.
- `./scripts/ci.sh`

Commit:

- `Implement shim authorization and exec planning`

## Step 5: BWS Provider Runtime Path

Scope:

- Add BWS provider client protocol.
- Add runtime operation that fetches exactly one approved secret.
- Add provider lease policy by environment: dev, staging, prod.
- Add rotation workflow state machine.

Verification:

- Contract tests cover one-secret fetch, no list/project operations, sink binding, provider lease expiry, prod per-fetch behavior, rotation invalidating leases, and no BWS token in audit.
- `./scripts/ci.sh`

Commit:

- `Implement BWS provider runtime contracts`

## Step 6: Local API Proxy Runtime

Scope:

- Add local HTTP proxy transport skeleton.
- Enforce profile-pinned upstream origin, path prefixes, methods, session token, and no body logging.
- Add request/response metadata redaction.
- Keep streaming/SSE extension points explicit.

Verification:

- Contract tests cover missing/wrong/expired token, method/path denial, cross-origin redirect denial, body logging disabled, and metadata redaction.
- `./scripts/ci.sh`

Commit:

- `Implement local API proxy runtime contracts`

## Step 7: Remote MCP Bridge Runtime

Scope:

- Add stdio JSON-RPC framing model.
- Add Streamable HTTP request model with Authorization injection and MCP-Session-Id propagation.
- Add conformance fixture runner scaffolding.
- Enforce pinned upstream profiles.

Verification:

- Contract tests cover initialization, session propagation, 401 challenge metadata, 404 reset metadata, invalid JSON-RPC, cancellation marker, no body logging, and cross-origin redirect denial.
- `./scripts/ci.sh`

Commit:

- `Implement MCP bridge runtime contracts`

## Step 8: macOS App, IPC, Local Secret Store, and LocalAuthentication Integration

Scope:

- Add macOS app bundle structure for approval renderer.
- Add XPC interface definitions for core/shim/helper communication.
- Add peer identity model for signed clients.
- Add local secret store access-control implementation notes and compile-time boundaries.
- Add LocalAuthentication approval service boundary.

Verification:

- Contract tests cover peer requirement matching model, wrong Team ID rejection model, old helper version rejection model, and approval digest binding.
- `./scripts/tahoe_compatibility_check.sh`

Commit:

- `Implement macOS integration boundaries`

## Step 9: Release Packaging and Notarization Readiness

Scope:

- Add Developer ID signing variables.
- Add notarization script that requires external credentials without reading secrets.
- Add entitlements diff gate.
- Add release artifact validation script.

Verification:

- Local ad-hoc package passes Tahoe gate.
- Scripts fail clearly when Developer ID/notary credentials are absent.
- `./scripts/tahoe_compatibility_check.sh`

Commit:

- `Implement release packaging readiness`

## Step 10: Threat Model and Operator Documentation

Scope:

- Add `Docs/THREAT_MODEL.md`.
- Add TCB, claims, non-claims, same-user malware limits, root/kernel non-goals.
- Add operational runbooks for recovery, adapter management, BWS rotation, proxy profiles, and MCP bridge profiles.

Verification:

- Documentation links to implemented contracts.
- Source sweeps verify no old names and no forbidden public secret API.
- `./scripts/ci.sh`

Commit:

- `Document threat model and operator workflows`
