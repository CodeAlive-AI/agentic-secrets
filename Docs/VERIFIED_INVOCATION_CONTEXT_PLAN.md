# Verified Invocation Context Plan

This plan improves the current parent-app and unlock-grant model without requiring EndpointSecurity, Developer ID, or restricted entitlements. It is the near-term path for reducing unnecessary LocalAuthentication prompts while preserving narrow, auditable secret delivery.

## Implementation Status

Implemented:

- `DeliveryRequest.parentApp` has been replaced with `originHint`.
- Decision manifests now carry `origin.hint`, `origin.provenanceConfidence`, `commandDigest`, `configContext`, and adapter identity.
- Short CLI delivery grants are action-bound and include action class, command digest, risk, config context, origin hint, provenance confidence, target identity, workspace, delivery mode, and secret alias.
- Persistent CLI authorization grants support `always` and `remember-24h` modes for matching non-destructive invocation contexts, use a device-local macOS Keychain signing key, and re-evaluate command policy every run.
- Active delivery grant summaries retain non-secret scope metadata for audit/UI explanation.
- LocalAuthentication prompt text shows `Parent app` and labels environment-derived/process-derived origin with explicit provenance.
- The shim no longer routes normal execution through the public CLI process; it invokes core directly for `run-cli`.
- Secret Broker IPC has a typed `create-shim-exec-plan` operation that returns core-side manifests without secret material.
- Unix socket IPC now derives observed peer evidence from the accepted socket and validates the observed process path/hash/cdhash against the install manifest instead of trusting the JSON `peer` value.

Remaining future work:

- Replace direct shim-to-core subprocess execution with the installed socket/XPC execution path once installer state reliably exposes the socket to shims.
- Add a production XPC transport with code-signing requirements.
- Add optional EndpointSecurity provenance assertions as described in `Docs/FUTURE_ENDPOINT_SECURITY.md`.

## Current Problem

The previous CLI runtime used `TERM_PROGRAM` as `parentApp`. That is only an environment hint. It can be absent, misleading, or intentionally spoofed.

The previous shim path also lost useful process context:

```text
registered CLI shim -> agentic-secrets CLI -> agentic-secrets-brokerd run-cli -> target CLI
```

In that path, the core run command saw the AgenticSecrets CLI process and inherited environment, not a verified origin for the app, terminal, editor, or agent that caused the invocation.

The old delivery grant scope was too broad for the documented short-grant model because `DeliveryGrantScope` did not include `actionClass`, command digest, risk, or config context. Short grants are now action-bound. Persistent authorization grants intentionally use a broader non-action scope, but command policy is re-evaluated before each secret delivery and destructive commands never reuse persistent grants.

## Design Goals

- Never treat environment variables as trusted identity.
- Make short delivery grants action-bound enough that one command cannot unlock a later destructive command.
- Keep non-destructive workflows fast after one local approval.
- Preserve fresh LocalAuthentication for destructive operations and for target, workspace, origin, config, delivery, or secret scope changes.
- Prefer macOS-provided peer identity over self-reported JSON fields.
- Keep the default self-build track free of restricted entitlements.

## Identity Layers

Agentic Secrets should model separate identities:

- `targetIdentity`: the registered CLI that will receive secret material.
- `injectorIdentity`: the AgenticSecrets component that asks core to prepare or perform delivery.
- `peerIdentity`: the process that connected to core IPC.
- `originHint`: untrusted context such as `TERM_PROGRAM`, shell, TTY, and environment-derived labels.
- `originIdentity`: verified or best-effort process-tree identity when available.
- `provenanceConfidence`: the confidence level attached to the origin evidence.

Suggested confidence levels:

- `none`: no origin evidence.
- `environmentHint`: environment-only hint such as `TERM_PROGRAM`.
- `processTree`: best-effort parent-process inspection.
- `socketPeer`: Unix socket credentials or audit token validated by core.
- `xpcPeer`: XPC peer requirement validated by macOS.
- `endpointSecurity`: optional future EndpointSecurity assertion.

## Step 1: Fix Unlock Grant Scope

Scope:

- Add `actionClass` to `DeliveryGrantScope`.
- Add a digest of `canonicalCommand` or a stable command-shape digest when available.
- Add `risk` or make risk derivable from the action-bound manifest.
- Add `configContext` or adapter lease invalidator digest so custom config, repo, host, and account changes do not reuse a grant.
- Keep `targetIdentity`, `targetResolvedPath`, `workspaceHash`, `secretAlias`, `environmentName`, and `deliveryMode`.
- Rename current `parentApp` in the scope to `originHint` until it is verified. Implemented as `originHint` plus `provenanceConfidence`.

Verification:

- A grant created for `supabase db pull` must not satisfy `supabase projects delete`.
- A grant created for one workspace must not satisfy another workspace.
- A grant created before target trust refresh must not satisfy the refreshed target identity.
- A grant created with a custom config flag must not satisfy the default config command, and vice versa.
- Contract tests must assert the documented scope fields.

## Step 2: Make Parent App Explicitly Untrusted

Scope:

- Rename `DeliveryRequest.parentApp` to either `originHint` or add a new field and deprecate the old meaning. Implemented as `DeliveryRequest.originHint`.
- Keep `TERM_PROGRAM` only as display context.
- Include origin hint in prompt text only when labelled as a hint.
- Do not use environment-only origin as a basis to skip LocalAuthentication for risky commands.

Verification:

- Manifest JSON distinguishes verified identity from hint identity.
- LocalAuthentication reason can show useful context without implying trust.
- Tests cover missing, spoofed, and changed `TERM_PROGRAM`.

## Step 3: Route Shim Requests Directly To Secret Broker

Scope:

- Replace `shim -> CLI -> core run-cli` with `shim -> core IPC`. The CLI hop is removed for shim execution; a typed `create-shim-exec-plan` IPC contract now exists for core-side planning.
- Make the shim send a typed request containing invoked name, argv, cwd, sanitized parent environment metadata, and target operation.
- Keep raw secret resolution in core only.
- Keep the target exec boundary small and testable.

Verification:

- Secret Broker receives the shim as the actual IPC peer.
- Help/version pass-through still avoids secret-store reads.
- Env scrubbing and collision denial behavior remains unchanged.
- Existing install manifest validation still works for self-build helpers.

## Step 4: Verify Unix Socket Peer Identity

Scope:

- On accepted Unix socket connections, core should collect peer credentials itself instead of trusting the `peer` field in request JSON.
- Use `getpeereid` for effective uid/gid.
- Use macOS Unix socket peer options such as `LOCAL_PEERTOKEN` where available to obtain an audit token.
- Use Security framework APIs such as `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity` to validate the running peer code from the audit token or pid.
- Compare the resulting path, owner, permissions, SHA-256, cdhash, and version to the install manifest.

Verification:

- A request with forged JSON peer identity is rejected when the socket peer does not match.
- A world-writable helper or parent directory remains rejected.
- A replaced helper binary is rejected even if request JSON claims the old identity.
- Contract tests cover missing peer-token support by falling back to stricter self-build hash validation.

## Step 5: Add XPC Peer Requirements

Scope:

- Add an XPC transport for installed app, core, and helpers.
- Use `xpc_connection_set_peer_code_signing_requirement` where the C XPC API is used.
- Use `NSXPCConnection.setCodeSigningRequirement` where NSXPC is used and the deployment target allows it.
- Keep Unix socket transport as a compatibility/self-build fallback until XPC install is production-ready.
- Keep hash/cdhash-based self-build validation available when Developer ID Team ID is absent.

Verification:

- Wrong Team ID, bundle identifier, version, cdhash, or debug signing state is rejected.
- Self-build mode still passes with install-manifest identity binding.
- XPC failure does not silently downgrade to accepting untrusted Unix socket peers.

## Step 6: Build A Prompt Policy Around Risk

Scope:

- Keep LocalAuthentication required when no matching valid grant exists.
- Allow non-destructive commands to reuse scoped authorization after a successful prompt without trying to prove read/write semantics.
- Require fresh LocalAuthentication for destructive commands, target identity changes, policy changes, custom config invalidators, and trust refresh.
- Support explicit modes: `always` by default, `remember-24h`, `short`, and `once`.

Suggested defaults:

- help/version/metadata: no secret read and no LocalAuthentication.
- default non-destructive CLI delivery: prompt once, then persistent `always` authorization for the same target, secret, workspace, origin, config, delivery mode, and CLI identity.
- `remember-24h`: same persistent scope with a 24-hour expiry.
- `short`: action-bound prompt reuse with the 300 second default TTL and 900 second maximum.
- destructive, forbidden, trust refresh, adapter install/revoke, policy update: fresh prompt or denial.

Verification:

- Prompt frequency is reduced for repeated matching non-destructive commands.
- A matching grant never bypasses policy evaluation.
- A short grant never applies to a different action class, while persistent grants are blocked before lookup for destructive commands.
- Cancellation still fails closed before any secret is resolved.

## Step 7: Audit And UI

Scope:

- Record provenance confidence, origin hint, verified peer identity, target identity, action class, workspace hash, grant reuse, and prompt outcome.
- Do not log raw secret values or token-shaped strings.
- Show active grants with action class and provenance confidence.
- Provide a clear "lock all grants" control.

Verification:

- Redacted audit export contains enough provenance to explain why a prompt was skipped.
- UI smoke tests cover active grant display and grant clearing.
- Secret-shaped audit metadata remains rejected.

## Non-Goals

- Proving the semantic intent of every shell command.
- Treating terminal environment as trusted identity.
- Requiring EndpointSecurity in the default release track.
- Treating code signature alone as approval to deliver a raw bearer secret forever.
- Removing LocalAuthentication for high-risk commands.

## Suggested Implementation Order

1. Add action-bound fields to `DeliveryGrantScope` and tests.
2. Rename or reclassify `parentApp` as an untrusted origin hint.
3. Add manifest and prompt fields for provenance confidence.
4. Route shim execution planning through core IPC directly.
5. Add Unix socket peer credential and audit-token validation.
6. Add XPC peer requirement transport.
7. Add risk-based prompt policy and UI/audit support for grant reuse.
8. Keep EndpointSecurity as the optional future provenance track described in `Docs/FUTURE_ENDPOINT_SECURITY.md`.
