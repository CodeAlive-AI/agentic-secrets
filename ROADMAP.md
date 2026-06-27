# Agentic Secrets Roadmap

This roadmap describes post-alpha product directions. It is not a release
commitment, but it should guide architecture decisions so short-term macOS work
does not block Linux, Windows, or richer audit workflows later.

Agentic Secrets remains a runtime secret protection system. It does not make
arbitrary command execution safe. Future work should keep secret access explicit,
narrow, approved, bounded, auditable, and fail-closed.

## Roadmap At A Glance

1. Cross-platform support with a reusable core for macOS, Linux, and Windows.
2. Full command audit and usage statistics without logging secret values.
3. Native workflows for OpenClaw, Hermes Agent, and other autonomous agents.
4. Rework API Sessions proxy delivery with a clear UX and verified end-to-end tests.
5. Finish Bitwarden Secrets preview with guided setup and tested provider flows.

## Direction 1: Cross-Platform Support With a Reusable Core

Goal: support macOS, Linux, and Windows without forking the product into three
unrelated implementations.

The preferred architecture is a reusable platform-neutral core with thin native
platform layers:

- `Core`: policy evaluation, decision manifests, adapter verification, lease
  rules, audit event construction, redaction, registry schema, rollback
  detection, and command classification.
- `Platform/macOS`: LocalAuthentication, Keychain or encrypted local store
  integration, LaunchAgent lifecycle, app bundle packaging, Unix domain socket
  authorization, and native SwiftUI UI.
- `Platform/Linux`: Secret Service or kernel-backed local storage options,
  systemd user service lifecycle, Unix domain socket authorization, desktop
  prompt integration, and distribution packaging.
- `Platform/Windows`: Windows Credential Manager or DPAPI-backed storage,
  Windows service or per-user background process lifecycle, named pipe
  authorization, Windows Hello or local credential prompt integration, and MSI
  or winget packaging.
  For DPAPI research, consider
  [GhostPack/SharpDPAPI](https://github.com/GhostPack/SharpDPAPI) only as a
  security-reference and test-planning tool: it documents and implements DPAPI
  masterkey, Credential Manager, Vault, certificate, browser, and machine-scope
  triage/decryption paths. That makes it useful for Windows threat modeling,
  compatibility checks, negative tests, and validating that Agentic Secrets does
  not accidentally create broad DPAPI recovery paths. It should not be bundled
  into the product, invoked by normal runtime flows, or treated as the Windows
  secret-delivery implementation.
- `Command Policy Packs`: dynamic signed command policy packs and deterministic decision manifests
  that remain portable unless a specific CLI requires platform-specific rules.
- `Tests`: contract tests shared across platforms, plus platform-specific
  conformance suites for identity, storage, IPC, lifecycle, and prompt behavior.

If the source tree needs platform-specific implementations, they should be
separated intentionally rather than mixed into core modules. A likely structure:

```text
Sources/Broker/
Sources/Platform/macOS/
Sources/Platform/Linux/
Sources/Platform/Windows/
Sources/App/macOS/
Sources/CLI/
Tests/CoreContracts/
Tests/PlatformContracts/
```

The core must not depend on a macOS-only API. Platform implementations should
satisfy small protocols owned by the core, such as secret storage, local
approval, process identity, IPC authorization, service lifecycle, filesystem
paths, and secure randomness.

Milestones:

1. Extract and document platform boundary protocols.
2. Move macOS-specific code behind `Platform/macOS` implementations.
3. Add a platform contract test suite that can run against fake platform
   providers in CI.
4. Build a Linux command-line prototype with local encrypted storage and user
   service lifecycle.
5. Build a Windows command-line prototype with DPAPI or Credential Manager
   storage and named pipe authorization.
6. Add native installer and repair flows for Linux and Windows only after the
   command-line contracts are stable.

Acceptance criteria:

- Core contract tests pass without macOS frameworks.
- Platform code cannot read provider secrets except through the approved secret
  authority boundary for that platform.
- Platform-specific storage, prompt, IPC, and service lifecycle behavior is
  covered by conformance tests.
- Documentation clearly states which security claims are common across all
  platforms and which claims are platform-specific.

## Direction 2: Full Command Audit and Usage Statistics

Goal: provide complete local auditability for command execution and secret
delivery without logging secret values or sensitive command bodies.

Agentic Secrets should answer operational questions such as:

- Who approved or initiated a command?
- When did it run?
- Which registered CLI, adapter, workspace, and target identity were involved?
- Which secret alias was delivered?
- How many times was a secret alias delivered in a selected time window?
- Which commands were denied, why, and under which policy epoch?
- Which approvals reused a scoped delivery grant instead of prompting again?

Audit records should include stable, redacted metadata:

- event ID, timestamp, hostname, local user ID, and session context;
- registered CLI name, invocation mode, adapter identity, adapter version, and
  adapter hash;
- target binary path, target identity digest, and command classification;
- workspace hash, command digest, action class, risk level, and delivery mode;
- secret alias, provider name, and provider record identifier where available;
- policy epoch, config hash, approval session ID, delivery grant ID, and lease
  scope;
- decision result, denial reason, error class, and repair hint;
- duration, exit status, and coarse success/failure outcome when available.

Audit records must not contain provider tokens, raw secret values, raw request
bodies, full environment snapshots, shell history, or unredacted command text.
When command visibility is useful, store deterministic digests plus an
adapter-provided redacted display form.

Usage statistics should be derived from the audit log rather than from a
separate source of truth. Initial views:

- secret alias usage count by day, CLI, adapter, workspace, and local user;
- command allow/deny counts by policy epoch and risk level;
- prompt frequency, delivery grant reuse, and grant expiry patterns;
- adapter version distribution and stale adapter usage;
- top denied actions and repair recommendations;
- exportable redacted reports for incident review and policy tuning.

Milestones:

1. Define a versioned audit event schema and migration policy.
2. Add append-only local audit storage with tamper-evident chaining or another
   integrity mechanism appropriate for local self-build use.
3. Add query APIs for time windows, CLI names, secret aliases, users, decisions,
   and policy epochs.
4. Add CLI commands for `audit list`, `audit show`, `audit stats`, and redacted
   export.
5. Add native app views for audit timeline, secret usage, command decisions,
   denials, and repair actions.
6. Add retention, pruning, and export settings that never weaken redaction.

Acceptance criteria:

- Every approved, denied, failed, and repaired secret-delivery decision creates
  an audit event.
- Statistics can report who ran which command, when it ran, which secret alias
  was delivered, and how often each alias was used.
- Audit export passes redaction gates and contract tests that use synthetic
  token-shaped values.
- Audit data remains useful after adapter upgrades, policy migrations, and
  platform-specific storage changes.

## Direction 3: Native Autonomous Agent Integrations

Goal: extend Agentic Secrets from registered local CLI delivery into native
workflows for OpenClaw, Hermes Agent, and other autonomous agents without
weakening the local secret-authority boundary.

Future integrations should expose bounded capabilities, pinned profiles, and
redacted audit events rather than raw secret retrieval APIs. The
[The-17/agentsecrets](https://github.com/The-17/agentsecrets) repository is a
useful source of approaches, implementations, and product ideas for
agent-facing secret workflows, but any borrowed pattern must preserve Agentic
Secrets' stricter approval, secret-delivery, and fail-closed guarantees.

## Direction 4: API Sessions Proxy UX

Goal: finish the local API Sessions proxy workflow before it returns to the
main macOS UI.

The current proxy runtime idea is useful: clients should call a short-lived
localhost session endpoint while Agentic Secrets keeps the real upstream API
key inside the local secret authority. However, the current product surface is
not ready for first-run users, so API Sessions should remain hidden from the
main sidebar and menu until the workflow is understandable and verified.

Milestones:

1. Define the primary user story and best next action for creating a proxy
   session without requiring implementation-context knowledge.
2. Design onboarding, empty states, repair states, and destructive cleanup for
   a tired, distracted, impatient user.
3. Add a guided flow that clearly distinguishes provider profile setup,
   local session creation, one-time token display, and session expiry.
4. Add end-to-end tests for profile creation, local session creation, token
   expiry, upstream request forwarding, redacted audit events, and failure
   recovery.
5. Re-enable the macOS sidebar/menu entry only after the UX and tests are in
   place.

Acceptance criteria:

- A new user can create and use a local API session without reading internal
  architecture docs.
- Secret values, upstream authorization headers, and request bodies are never
  displayed or logged.
- Failure states explain whether the daemon, profile, session token, or
  upstream call is broken and provide one clear next action.
- UI smoke and contract tests cover the complete happy path and major failure
  paths before the feature is visible by default.

## Direction 5: Bitwarden Secrets Preview

Goal: move Bitwarden Secrets from preview to a finished, tested provider
workflow.

The current Bitwarden surface is useful for early validation, but it should
remain clearly marked as preview until the setup, repair, credential lifecycle,
and failure states are understandable without implementation knowledge.

Milestones:

1. Design a guided setup flow that explains project ID, secret ID, environment,
   local approval behavior, and what Agentic Secrets stores.
2. Add clear empty, repair, rotation, delete, and provider-auth failure states
   with one best next action.
3. Verify that no Bitwarden token, fetched secret value, or upstream identifier
   is displayed or logged beyond redacted metadata.
4. Add end-to-end tests for binding creation, provider fetch, lease behavior,
   rotation, deletion, redacted audit output, and provider failure recovery.
5. Remove the preview label only after the UI and tests are complete.

Acceptance criteria:

- A new user can configure Bitwarden Secrets from the app without reading
  internal docs.
- The UI explains exactly which local metadata is stored and which upstream
  secret is referenced.
- Provider failures identify whether local config, provider auth, project ID,
  secret ID, or lease state needs action.
- UI smoke and contract tests cover happy path and major failure paths before
  Bitwarden is presented as a stable feature.

## Roadmap Principles

- Keep the secret authority small and platform-explicit.
- Keep policy decisions deterministic and testable.
- Prefer shared contracts over shared assumptions.
- Treat auditability as a product surface, not only a debug log.
- Add platform support only when the security boundary for that platform is
  documented, testable, and honest about its limits.
