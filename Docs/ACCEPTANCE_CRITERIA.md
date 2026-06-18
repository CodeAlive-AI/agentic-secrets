# Production Acceptance Criteria Without Developer ID

This document defines the acceptance criteria for a production-ready AgenticFortress release whose default distribution model is open-source self-build plus local ad-hoc signing.

Developer ID signing, notarization, stapling, and Gatekeeper-friendly downloadable binaries are explicitly out of scope for this acceptance set. They remain optional maintainer work described in `Docs/FUTURE_DEVELOPER_ID.md`.

## Release Definition

A release is accepted as production-ready for the no-Developer-ID track when:

- a user can clone, build, package, install, run, update, and uninstall AgenticFortress without an Apple Developer Program account;
- all shipped executables are locally ad-hoc signed and pass local code-signing validation;
- `agentic-fortressd-core` is the only component allowed to read local secret material;
- helpers communicate with core through authenticated local IPC/XPC and never read secrets directly;
- every secret delivery is tied to a decision manifest, policy epoch, target identity, approval session, and audit record;
- every acceptance criterion below has concrete evidence from automated tests, local Tahoe gates, or an explicit interactive verification transcript.

## Evidence Levels

| Level | Meaning | Acceptable evidence |
| --- | --- | --- |
| Automated | Must run without user interaction. | `./scripts/ci.sh`, contract tests, static checks, packaging checks. |
| Local macOS | Must run on supported macOS with current SDK. | `./scripts/tahoe_compatibility_check.sh`, codesign validation, local app launch smoke tests. |
| Interactive | Requires a user prompt or local credential store. | LocalAuthentication prompt transcript, UI screenshot, recorded command output with secrets redacted. |
| Manual review | Human review required because the claim cannot be fully automated. | Threat-model sign-off, release checklist sign-off, docs review. |

No acceptance criterion may rely on reading, printing, or grepping secret values.

If a verification command in this document does not exist yet, implementing that command is part of satisfying the corresponding acceptance criterion.

## Top-Level Gates

### AC-GATE-001: Self-Build Release Track Is Explicit

Pass condition:

- The release report exposes a machine-readable `canRunLocal` or equivalent self-build readiness field.
- The release report does not require Developer ID or notarization for the self-build track.
- Developer ID binary distribution readiness is reported separately.

Verification:

```sh
swift run agentic-fortress release-gates
```

Required evidence:

- JSON output shows local self-build readiness separately from optional binary distribution readiness.
- No self-build gate fails solely because Developer ID credentials are absent.

Failure examples:

- A single `canRelease=false` blocks local self-build because notarization is unavailable.
- Developer ID environment variables are required by `./scripts/ci.sh`.

### AC-GATE-002: CI Is Strict and Reproducible

Pass condition:

- Debug and Release builds pass with warnings treated as errors.
- Contract tests run after compilation.
- CI does not require local secrets, Keychain credentials, Developer ID identities, or notary profiles.

Verification:

```sh
./scripts/ci.sh
```

Required evidence:

- Command exits `0`.
- Build log includes Debug build, Release build, and `AgenticFortress contract tests passed`.

Failure examples:

- CI only builds Debug.
- CI silently ignores Swift compiler warnings.
- CI depends on a local `.env`, shell rc file, or keychain secret.

### AC-GATE-003: Tahoe Local Compatibility Gate Passes

Pass condition:

- The local package builds and validates on macOS Tahoe 26.x with macOS 26 SDK or newer.
- The app bundle passes local ad-hoc code-signing validation.
- The app bundle and every shipped executable match the approved local self-build entitlement baseline.

Verification:

```sh
./scripts/tahoe_compatibility_check.sh
```

Required evidence:

- Command exits `0`.
- Output includes OS/SDK 26.x compatibility, successful package validation, codesign verification, and entitlement diff verification.

Failure examples:

- Package validation requires Developer ID.
- The app bundle contains unsigned helper executables.
- Entitlements drift without an explicit approved baseline update.

## Distribution and Install

### AC-DIST-001: Source-First Install Works From a Clean Checkout

Pass condition:

- A clean clone can build, package, and install locally without private files.
- The install path is deterministic and documented.
- The install does not require disabling Gatekeeper, SIP, or other macOS security features.

Verification:

```sh
git clone "$REPO_URL" "$TMPDIR/agentic-fortress-clean"
cd "$TMPDIR/agentic-fortress-clean"
./scripts/ci.sh
./scripts/package_release.sh
./scripts/validate_release_artifact.sh build/AgenticFortress.app
```

Required evidence:

- Commands exit `0`.
- Documentation explains the self-build path.

Failure examples:

- Installation instructions require `xattr -rd com.apple.quarantine` as a normal step.
- A required file exists only on the maintainer machine.

### AC-DIST-002: Local Ad-Hoc Signing Is Complete

Pass condition:

- Every shipped executable and bundle is ad-hoc signed.
- Hardened runtime is enabled where supported by the local packaging path.
- Code-signing validation is part of the package validation script.
- No shipped executable carries restricted entitlements that make ad-hoc self-build execution fail on Tahoe.

Verification:

```sh
./scripts/package_release.sh
./scripts/validate_release_artifact.sh build/AgenticFortress.app
codesign --verify --strict --deep --verbose=4 build/AgenticFortress.app
./scripts/check_entitlements_diff.sh build/AgenticFortress.app
```

Required evidence:

- All commands exit `0`.
- `codesign` output confirms the app satisfies its designated requirement.
- Entitlement diff confirms the app and every helper use the approved self-build baseline.

Failure examples:

- A helper binary is copied after signing.
- Package validation checks only the main executable.

### AC-DIST-003: Uninstall Removes Runtime Surface Without Deleting User Secrets By Accident

Pass condition:

- The product has an uninstall command or script.
- Uninstall removes launch agents, sockets, shims, temporary files, and installed app files.
- Local secret records and policy state are retained or removed only according to an explicit user-selected mode.

Verification:

```sh
./scripts/install_local.sh --prefix "$TMPDIR/agentic-fortress-ac"
./scripts/uninstall_local.sh --prefix "$TMPDIR/agentic-fortress-ac" --keep-secrets
./scripts/uninstall_local.sh --prefix "$TMPDIR/agentic-fortress-ac" --purge-local-state
```

Required evidence:

- Automated install/uninstall smoke test exits `0`.
- Logs do not print secret values.

Failure examples:

- Uninstall leaves active launch agents.
- Uninstall deletes local secret records without explicit purge mode.

### AC-DIST-004: Native App Lifecycle UX Has Install and Repair Path

Pass condition:

- The SwiftUI app checks core daemon reachability on launch, refresh, and app activation.
- If IPC is unavailable, the UI shows daemon status, socket path, LaunchAgent path when known, and install/repair actions when the local app bundle supports them.
- Diagnostics shows a concrete install plan before writing files: app copy, helper links, state directory, run directory, install manifest, LaunchAgent, and socket path.
- Install and repair actions require explicit confirmation and use the existing per-user LaunchAgent and install manifest model; the UI does not become the secret authority.
- If the app is launched outside the install prefix, the UI explains that the installed copy should be opened after install because IPC authorization is bound to the installed bundle path.
- Menu bar status reflects healthy, attention, locked, and daemon-unavailable states.

Verification:

```sh
./script/ui_smoke.sh
./script/build_and_run.sh --verify
```

Required evidence:

- UI smoke covers empty state, daemon unavailable state, install plan state, register wizard validation, selection/search after refresh, and menu bar status.
- App launch smoke exits `0` without requiring real provider tokens or Keychain secrets.

Failure examples:

- Daemon IPC failure appears only as a raw error alert with no recovery path.
- Install runs without showing what files and LaunchAgent will change.
- The app reads local secret material directly to bypass daemon failure.
- Menu bar status remains stale after daemon health changes.

## Process Architecture and IPC

### AC-IPC-001: Core Owns Secret Authority

Pass condition:

- Only `agentic-fortressd-core` imports and uses the production local secret resolution path.
- `agentic-fortress-shim`, `agentic-fortress-proxyd`, `agentic-fortress-bwsd`, and `agentic-fortress-mcpd` do not call `SecItemCopyMatching` or instantiate production local secret stores for secret material.
- Helpers receive narrow capabilities or execution plans, not raw secret read authority.

Verification:

```sh
rg "SecItemCopyMatching|KeychainSecretStore|LocalEncryptedSecretStore|resolve\\(" Sources
./scripts/check_secret_authority.sh
./scripts/ci.sh
```

Required evidence:

- Static scan shows production secret resolution only in core-owned modules.
- Contract tests cover helper behavior without direct local secret store access.

Failure examples:

- A helper reads local secret material directly.
- A helper exposes a public "get secret" operation.

### AC-IPC-002: Local IPC Authenticates Helpers Without Developer ID

Pass condition:

- The self-build trust model authenticates helpers by install manifest, resolved path, owner, permissions, version, and binary hash/cdhash.
- IPC requests are rejected when the helper path, hash, version, or permissions do not match policy.
- Developer ID Team ID checks are optional and not required in self-build mode.

Verification:

```sh
swift run agentic-fortress-contract-tests
```

Required evidence:

- Tests cover accepted helper identity, wrong hash, wrong path, world-writable parent, old version, and debug/test override behavior.

Failure examples:

- IPC accepts any same-user process.
- IPC trusts only process name.
- Self-build mode still requires Team ID.

### AC-IPC-003: XPC or Local IPC Is the Only Runtime Control Plane

Pass condition:

- Helpers call core through one documented local IPC/XPC protocol.
- Runtime authorization is not performed through environment variables, temporary plaintext files, or shell command substitution.
- IPC message schemas are versioned and Codable/structured.

Verification:

```sh
swift run agentic-fortress ipc-conformance
swift run agentic-fortress-contract-tests
```

Required evidence:

- Conformance output lists protocol version, message types, and compatibility status.
- Negative tests reject unknown message versions and malformed requests.

Failure examples:

- Shim invokes core by passing secret-bearing JSON through argv.
- A helper writes a secret request to `/tmp` for core to poll.

### AC-IPC-004: Untrusted Complex Parsers Stay Outside Secret Authority

Pass condition:

- Management IPC remains typed, versioned, length-prefixed Codable messages.
- Any future parser for untrusted complex raw protocols, including adapter fixture formats, MCP body streams, SSH-like binary payloads, or provider-specific envelopes, runs outside the core secret authority path in a helper/XPC-style process boundary.
- Core receives only narrow typed parser results and never hands local secret store authority to the parser process.
- Malformed parser fixtures fail closed and do not produce audit records containing raw body or secret-shaped values.

Verification:

```sh
swift run agentic-fortress-contract-tests
./scripts/check_secret_authority.sh
```

Required evidence:

- New raw parser work includes fixed valid and malformed fixtures.
- Static secret-authority checks still prove only core can resolve local secret material.
- Architecture review identifies the parser boundary before merge.

Failure examples:

- A future MCP or adapter parser is linked directly into secret resolution code.
- Parser errors are converted into permissive delivery decisions.
- Raw request or response bodies are written to audit logs.

## Local Secret Storage and Local Authentication

### AC-KEY-001: No Shared Keychain Access Group Is Required

Pass condition:

- Default entitlements do not include a shared Keychain access group.
- Only core reads local secret material.
- Helpers cannot resolve local secrets directly.
- Default self-build binaries do not use restricted Keychain entitlements.

Verification:

```sh
codesign -d --entitlements :- build/AgenticFortress.app
codesign -d --entitlements :- build/AgenticFortress.app/Contents/MacOS/agentic-fortressd-core
rg "kSecAttrAccessGroup|keychain-access-groups|com.apple.security.application-groups" Sources packaging Docs README.md --glob '!ACCEPTANCE_CRITERIA.md'
./scripts/check_secret_authority.sh
```

Required evidence:

- App, core, and helper entitlements plus source scan show no default shared Keychain access group.
- Self-build entitlements contain no restricted app identity or Keychain sharing capability.
- If access-group strings exist, they are documented as optional future Developer ID-only work.

Failure examples:

- All helpers share direct Keychain access.
- Access groups are required for local self-build.

### AC-KEY-002: Local Secret Records Are Device-Local and User-Presence Gated

Pass condition:

- Default self-build secret material is stored in an owner-only local encrypted file store.
- Local encrypted store and key files are owner-only (`0600`) under owner-only directories (`0700`).
- Production secret reads require LocalAuthentication user presence before decrypt.
- Keychain-backed storage remains an optional provisioned-signing backend, not required for no-Developer-ID self-build acceptance.

Verification:

```sh
swift run agentic-fortress-contract-tests
```

Required evidence:

- Tests assert local encrypted store metadata, no plaintext secret material in the store file, owner-only file permissions, LocalAuthentication cancellation mapping, and optional provisioned Keychain query construction.

Failure examples:

- Secrets are synchronizable by default.
- Secrets are readable while the device is locked.
- Production default bypasses LocalAuthentication.
- Self-build requires restricted entitlements or provisioning profiles.

### AC-KEY-003: LocalAuthentication Prompt Is Decision-Bound

Pass condition:

- The prompt reason includes manifest digest, action class, target command, workspace, secret alias, and delivery mode.
- Approval proof expires quickly and is bound to the decision manifest.
- Prompt cancellation denies the operation without reading the secret.
- Repeated CLI runs may use a signed authorization grant only when CLI name, target identity, workspace hash, config context, untrusted origin hint, provenance confidence, delivery mode, and secret alias match. Short grants additionally require action class, command digest, and risk to match. Command policy is still evaluated before each secret delivery, and destructive commands require fresh approval.
- CLI authorization grants store no secret material. Default persistent grants use `always` and are signed with a device-local macOS Keychain key, `remember-24h` expires after 24 hours, `short` expires by default after 300 seconds and cannot exceed 900 seconds, and `once` disables reuse.

Verification:

```sh
swift run agentic-fortress-contract-tests
./scripts/interactive_keychain_prompt_check.sh
AGENTIC_FORTRESS_INTERACTIVE=1 AGENTIC_FORTRESS_EXPECT_CANCEL=1 ./scripts/interactive_keychain_prompt_check.sh
```

Required evidence:

- Automated tests cover prompt reason construction and proof expiry.
- Automated tests cover short unlock grant TTL, expiry, tamper rejection, scope mismatch, and rejection across different action classes, destructive actions, workspaces, origin hints, and custom config contexts.
- Automated tests cover persistent authorization default `always`, `remember-24h` expiry, protected signing keys, tamper rejection, scope mismatch, reuse across non-destructive action classes, and destructive policy gating.
- The interactive script uses the packaged, ad-hoc signed core binary so the Tahoe no-Developer-ID runtime path is exercised.
- Interactive transcript confirms the macOS prompt appears before secret resolution and cancellation denies access with `userCanceled`.

Failure examples:

- Prompt says only "AgenticFortress wants to access a local secret".
- A prompt approval can be replayed for a different target or workspace.
- A local authorization grant can be edited to extend expiry.

## Shim and CLI Env Delivery

### AC-SHIM-001: Shim Never Trusts Invocation Name Alone

Pass condition:

- Symlink or argv invocation name is treated as untrusted input.
- Target path is resolved from policy.
- Target identity is assessed before execution.
- Registered CLI trust metadata is not trusted unless its integrity sidecar verifies.
- Registered CLI trust refresh requires local authorization before writing new trust metadata.

Verification:

```sh
swift run agentic-fortress-contract-tests
```

Required evidence:

- Tests cover spoofed invocation name, policy target resolution, target hash binding, registry tamper rejection, denied trust refresh, and target-change race during trust refresh.

Failure examples:

- `/tmp/hcloud` can choose its own target path.
- Changing the target binary after approval is not detected.
- Editing `cli-registry.json` to point at another target still allows secret resolution.
- `trust-refresh` can silently rebind a CLI target without local authorization.

### AC-SHIM-002: Environment Injection Uses a Fresh Scrubbed Environment

Pass condition:

- Parent secret-like environment variables are removed.
- Target environment variable collisions fail closed.
- Generic runners do not receive raw secret env delivery by default.

Verification:

```sh
swift run agentic-fortress-contract-tests
```

Required evidence:

- Tests cover inherited secret scrubbing, collision denial, and generic runner denial.

Failure examples:

- Parent `OPENAI_API_KEY` survives into target process.
- `npm run dev` receives a raw API key by default.

### AC-SHIM-003: Optional CLI Shim Is Explicit and Passes Help/Version Without Secret Delivery

Pass condition:

- Per-CLI shim installation is opt-in through `agentic-fortress cli shim install <name>`.
- Shim installation creates a symlink to the installed `agentic-fortress-shim` binary, not a generated shell wrapper.
- Shim installation does not replace or modify the native CLI binary.
- Normal shimmed commands route through `agentic-fortress cli run <name> -- ...`.
- Global help/version commands pass through to the registered target without resolving or injecting secrets.
- Global help/version pass-through avoids LocalAuthentication and Keychain integrity-key prompts.
- Pass-through execution still scrubs inherited secret-like environment variables.

Verification:

```sh
swift run agentic-fortress-contract-tests
swift build
```

Required evidence:

- Contract tests cover the global help/version pass-through predicate.
- A local smoke test registers a fake CLI with a synthetic token, installs a temporary shim, runs `<name> --version`, and proves the target does not receive the registered environment variable.

Failure examples:

- Installing a shim overwrites `/opt/homebrew/bin/hcloud`.
- `hcloud version` passes through without resolving or receiving `HCLOUD_TOKEN`.
- A generated shell wrapper contains product logic or a secret value.

### AC-SHIM-004: Exec Plan Is Single-Use and Bound

Pass condition:

- Core returns a single-use invocation handle.
- The handle binds peer identity, injector identity, target identity, action class, workspace, untrusted origin hint, policy epoch, and delivery mode.
- Replaying the handle fails.

Verification:

```sh
swift run agentic-fortress-contract-tests
```

Required evidence:

- Tests cover successful consume and replay denial.

Failure examples:

- A handle generated for one target can be reused for another.
- Handles survive policy epoch changes.

## Dynamic Adapters and Policy

### AC-ADAPT-001: External Adapter Packs Are Signed Data, Not Code Execution

Pass condition:

- Adapter packs are verified as signed declarative data.
- Pack registration enforces trusted key id, publisher allowlist, CLI allowlist, schema version, expiry, rule validation, and rollback checks.
- Adapter packs cannot execute arbitrary code during classification.

Verification:

```sh
swift run agentic-fortress-contract-tests
swift run agentic-fortress adapter list
```

Required evidence:

- Tests cover invalid signature, untrusted key, expired pack, denied publisher, denied CLI, duplicate rules, destructive-looking read-only claims, rollback, and golden fixture mismatch.

Failure examples:

- Adapter pack contains script hooks.
- A pack can lower risk for a destructive action without tests failing.

### AC-POLICY-001: Policy State Is Tamper-Evident and Secret-Free

Pass condition:

- Policy database is MACed or otherwise tamper-evident.
- Plaintext secret-like material is rejected before save/export.
- Rollback mismatch locks policy and clears remembered leases.

Verification:

```sh
swift run agentic-fortress-contract-tests
```

Required evidence:

- Tests cover MAC mismatch, plaintext-secret rejection, rollback lock, remembered lease clearing, and recovery bundle no-token invariant.

Failure examples:

- Editing policy JSON by hand is accepted.
- Recovery bundle includes provider tokens.

## Provider, Proxy, and MCP Paths

### AC-BWS-001: BWS Provider Fetches Exactly One Approved Secret

Pass condition:

- Runtime BWS operation is scoped to one approved alias and one approved sink.
- List/project-wide operations are unavailable from the runtime path.
- Provider leases expire and are invalidated by rotation.

Verification:

```sh
swift run agentic-fortress-contract-tests
```

Required evidence:

- Tests cover one-secret fetch, no list/project operations, sink binding, lease expiry, prod per-fetch behavior, and rotation invalidation.

Failure examples:

- BWS helper can enumerate all project secrets.
- Rotation leaves old provider lease active.

### AC-PROXY-001: Local Proxy Uses Pinned Upstream Profiles

Pass condition:

- Proxy session is bound to a configured upstream origin, path prefixes, methods, session token, and TTL.
- Cross-origin redirects are denied.
- Request and response bodies are not logged by default.

Verification:

```sh
swift run agentic-fortress-contract-tests
```

Required evidence:

- Tests cover missing/wrong/expired token, method/path denial, cross-origin redirect denial, body logging disabled, and redacted metadata.

Failure examples:

- A local app can redirect the proxy to an attacker origin.
- Proxy logs request bodies containing secrets.

### AC-MCP-001: MCP Bridge Injects Authorization Only for Pinned Profiles

Pass condition:

- MCP bridge validates upstream profile and path before injecting Authorization.
- MCP session id propagation follows protocol state.
- Invalid JSON-RPC and cancellation markers are handled without leaking Authorization.

Verification:

```sh
swift run agentic-fortress-contract-tests
swift run agentic-fortress mcp-conformance
```

Required evidence:

- Tests cover initialization, session propagation, 401 metadata, 404 reset metadata, invalid JSON-RPC, cancellation marker, no body logging, and redirect denial.

Failure examples:

- Authorization header is injected for an unpinned origin.
- MCP bridge logs bearer tokens.

## Audit, Redaction, and Operations

### AC-AUDIT-001: Audit Is Complete Enough to Reconstruct Decisions Without Secrets

Pass condition:

- Every approved or denied delivery writes a structured audit event.
- Audit includes decision digest, action class, target identity, workspace hash, policy epoch, approval option, and outcome.
- Audit never includes raw secret material, provider tokens, full Authorization headers, or request bodies by default.

Verification:

```sh
swift run agentic-fortress-contract-tests
swift run agentic-fortress redact "OPENAI_API_KEY=sk-example"
```

Required evidence:

- Tests cover redaction of secret-like values and no-token audit/export invariants.

Failure examples:

- Audit stores full bearer token.
- Denied operations leave no audit event.

### AC-OPS-001: Operator Workflows Are Documented and Testable

Pass condition:

- Documentation covers install, update, uninstall, adapter management, BWS rotation, proxy profiles, MCP profiles, rollback recovery, and diagnostics.
- Each workflow has a command-level smoke test or explicit manual verification step.
- Documentation does not instruct users to weaken macOS security settings.

Verification:

```sh
rg "disable Gatekeeper|disable SIP|xattr -rd com.apple.quarantine" README.md Docs scripts --glob '!ACCEPTANCE_CRITERIA.md'
./scripts/ci.sh
```

Required evidence:

- Search returns no normal-path security bypass instruction.
- Operations doc links to the acceptance criteria and threat model.

Failure examples:

- Install docs rely on disabling Gatekeeper.
- Recovery docs tell users to paste provider tokens into config files.

## Security Review

### AC-SEC-001: STRIDE Review Has No Unowned High-Severity Findings

Pass condition:

- Threat model covers spoofing, tampering, repudiation, information disclosure, denial of service, and elevation of privilege for each runtime boundary.
- Every high-severity finding has an owner, mitigation, and test or explicit accepted-risk entry.
- Same-user malware, root compromise, kernel compromise, malicious target CLI, and upstream provider compromise are documented as limits or non-goals.

Verification:

```sh
rg "Spoofing|Tampering|Repudiation|Information Disclosure|Denial of Service|Elevation of Privilege" Docs/THREAT_MODEL.md
```

Required evidence:

- Threat model contains STRIDE coverage and residual risk decisions.

Failure examples:

- A high-severity spoofing issue has no mitigation and no accepted-risk note.
- Threat model claims to make arbitrary target execution safe.

### AC-SEC-002: Public API Has No Raw Secret Getter

Pass condition:

- Public API does not expose `getSecret`, `readSecret`, `dumpSecret`, or equivalent raw secret extraction operations.
- Secret material can only move through approved delivery-specific paths.

Verification:

```sh
swift run agentic-fortress-contract-tests
rg "public .*getSecret|public .*readSecret|public .*dumpSecret" Sources
```

Required evidence:

- Contract tripwire catches forbidden public secret API.
- Static scan has no forbidden public APIs.

Failure examples:

- A convenience CLI command prints a secret to stdout.
- A public API returns raw `SecretMaterial` without delivery binding.

## Documentation and Release Artifacts

### AC-DOC-001: Docs Match the No-Developer-ID Track

Pass condition:

- README and operations docs identify self-build/ad-hoc signing as the default path.
- Developer ID is documented only as optional future maintainer binary distribution work.
- Acceptance criteria, threat model, implementation map, and operations docs cross-reference each other.

Verification:

```sh
rg "Developer ID|self-build|ad-hoc|ACCEPTANCE_CRITERIA" README.md Docs
```

Required evidence:

- Search output confirms consistent terminology.

Failure examples:

- README implies Developer ID is required for local use.
- Operations docs mix self-build and notarized-binary release gates.

### AC-DOC-002: Release Notes Include Verification Evidence

Pass condition:

- Every production release includes the exact commit, OS version, SDK version, Swift version, and verification commands run.
- Release notes state whether the artifact is self-build source release or optional notarized binary release.
- Release notes list known residual risks.

Verification:

```sh
./scripts/create_release_evidence.sh
```

Required evidence:

- Generated release evidence file contains commit hash, toolchain versions, gate results, and residual risks.

Failure examples:

- Release notes say "production-ready" without evidence.
- Known blocked gates are omitted.

## Final Acceptance Checklist

A no-Developer-ID production release is accepted only when all of these are true:

- [ ] `AC-GATE-001` through `AC-GATE-003` pass.
- [ ] `AC-DIST-001` through `AC-DIST-004` pass.
- [ ] `AC-IPC-001` through `AC-IPC-004` pass.
- [ ] `AC-KEY-001` through `AC-KEY-003` pass.
- [ ] `AC-SHIM-001` through `AC-SHIM-004` pass.
- [ ] `AC-ADAPT-001` and `AC-POLICY-001` pass.
- [ ] `AC-BWS-001`, `AC-PROXY-001`, and `AC-MCP-001` pass.
- [ ] `AC-AUDIT-001` and `AC-OPS-001` pass.
- [ ] `AC-SEC-001` and `AC-SEC-002` pass.
- [ ] `AC-DOC-001` and `AC-DOC-002` pass.
- [ ] No acceptance evidence contains raw secret values.
- [ ] No accepted path requires an Apple Developer Program account.
