# Windows Support Plan

This document defines the first Windows support slice for Agentic Secrets. It is
an implementation plan, not a release commitment.

The supported Windows baseline for this plan is Windows 11.

## Goal

Build a Windows command-line runtime that can safely deliver approved secrets as
environment variables to a newly launched child process.

Initial support should preserve the Agentic Secrets product boundary:

- secret delivery is explicit, narrow, approved, bounded, auditable, and
  fail-closed;
- secrets are not written to `.env` files, shell profiles, persistent user or
  system environment variables, command-line arguments, registry run keys, or
  debug logs;
- the runtime does not claim to make arbitrary command execution safe.

## Non-Goals

Initial support does not include:

- a native Windows desktop UI;
- the future Avalonia Windows/Linux desktop UI;
- Windows Hello approval;
- MSI, winget, or enterprise deployment;
- Windows service installation under `LocalSystem`;
- remote delivery;
- API session proxy support;
- MCP bridge support;
- protection from local admin, kernel compromise, same-user debugger access,
  same-user malware with sufficient process access, or a compromised approved
  child process.

## Language Choice

Use Rust for the Windows secret-bearing runtime.

Rust is the preferred implementation language for:

- the per-user broker process;
- the command runner/shim;
- DPAPI and future DPAPI-NG storage abstractions;
- named pipe IPC and caller authentication;
- `CreateProcessW` child process launch;
- Windows Job Object process-tree accounting.

C#/.NET may be considered later for a Windows management UI or non-secret
installer/repair workflows. If Windows and Linux share one future desktop UI,
prefer Avalonia on the latest stable release available at implementation time.
As of 2026-06-27, the current stable Avalonia package/release is 12.0.5. Do not
pin this plan to preview or nightly Avalonia builds. C#/.NET should not be the
default choice for the initial secret-bearing hot path because managed strings, GC
behavior, and Win32 interop make secret-buffer lifetime and copy control harder
to reason about.

Go is acceptable for exploratory CLI experiments, but it is not the preferred
production language for initial Windows support. The Windows boundary requires precise Win32 interop,
security descriptors, process identity checks, environment blocks, and handle
lifetime control; Rust is a better fit for that runtime.

## Architecture

Keep the Windows implementation separate from the current Swift/macOS codebase,
but make it conform to shared product contracts.

Initial source layout:

```text
platform/windows/
  Cargo.toml
  crates/
    agentic-secrets-win-broker/
    agentic-secrets-win-run/
    agentic-secrets-win-ipc/
    agentic-secrets-win-store/
    agentic-secrets-win-contracts/
  tests/
    env_delivery_contracts.rs
    named_pipe_auth_contracts.rs
    dpapi_store_contracts.rs
```

Future Windows/Linux UI layout:

```text
ui/
  AgenticSecrets.Desktop/
    AgenticSecrets.Desktop.csproj
    Platforms/
      Windows/
      Linux/
```

The future shared desktop UI should use Avalonia when Linux desktop support is a
near-term product goal. The UI must remain outside the secret authority: it can
display state, approvals, audit events, diagnostics, repair flows, and policy
pack management, but broker-owned Rust processes continue to own secret storage,
policy evaluation, and process launch.

Shared behavior should live first as schemas, fixtures, and contract tests, not
as a premature cross-platform Rust core:

```text
Docs/contracts/
Tests/ContractFixtures/
```

Candidate shared contracts:

- command policy pack schema;
- deterministic decision manifest schema and digest fixtures;
- audit event schema;
- redaction fixtures;
- rollback and integrity envelope fixtures;
- delivery grant shape and expiry semantics.

Do not extract a shared Rust core until both the macOS and Windows
implementations have proven which behavior is genuinely stable and worth
sharing.

## Runtime Components

### Per-User Broker

`agentic-secrets-win-broker.exe` owns:

- policy evaluation;
- approval and remembered grant decisions;
- secret store access;
- audit event creation;
- rollback and integrity checks;
- IPC authorization;
- delivery plan issuance.

The broker should run as a per-user process initially. Avoid a `LocalSystem`
Windows service until there is a concrete enterprise deployment need and a
separate threat model.

### Runner

`agentic-secrets-run.exe` is a short-lived command runner:

```powershell
agentic-secrets run --profile openai -- npm test
```

The runner:

- captures invocation context;
- resolves the target executable path;
- computes command and target identity digests;
- contacts the per-user broker over a named pipe;
- receives a bounded one-time delivery plan;
- builds an explicit sanitized environment block;
- launches the child with `CreateProcessW`;
- assigns the child to a Windows Job Object;
- returns exit status and redacted outcome metadata to the broker.

The runner must not read the production secret store directly.

### Storage

Use a broker-owned DPAPI-protected file store initially.

Credential Manager may be researched for specific integration cases, but it
should not be the primary source of truth. Agentic Secrets needs versioned
policy, audit, rollback, and integrity envelopes that are easier to own and test
in a broker-controlled store.

DPAPI protects data at rest under the Windows logon context. It does not by
itself provide user presence or runtime approval semantics. Those remain
Agentic Secrets responsibilities.

Track DPAPI-NG / CNG DPAPI as future research for enterprise or domain-bound
protection scenarios.

### IPC

Use a local named pipe:

```text
\\.\pipe\agentic-secrets\<user-sid>\broker
```

Initial IPC requirements:

- pipe ACL allows only the current user SID and required system accounts;
- pipe name is not treated as a secret;
- every request carries a nonce, timestamp, protocol version, and operation
  type;
- broker obtains the client process ID where available;
- broker validates caller token/SID and expected runner identity;
- broker rejects unsupported protocol versions and malformed payloads;
- broker fails closed on identity mismatch, stale nonce, expired request, or
  policy rollback lock.

Use typed, versioned messages. Avoid parsing complex untrusted protocols inside
the secret authority.

### Environment Delivery

Use `CreateProcessW` with an explicit Unicode environment block. Do not rely on
ambient environment inheritance.

Environment construction rules:

- start from a small allowlist required for normal Windows process startup, such
  as `SystemRoot`, `PATH`, `TEMP`, and `TMP`;
- scrub inherited secret-shaped variables;
- fail closed when an injected secret name collides with an existing variable;
- never put secret values in `argv`;
- never write the generated environment block to disk or logs;
- zeroize runner-side secret buffers best-effort after process launch;
- audit only aliases, digests, policy epoch, action class, and redacted display
  forms.

Environment delivery is a compatibility mode, not a claim that the secret is
unreadable after launch. Once a child process receives an environment variable,
that child owns the value. Local admin, debuggers, sufficiently privileged
same-user processes, crash dumps, or the child process itself may expose it.

### Future Delivery Sinks

Design the runner around a `DeliverySink` abstraction from the beginning, even
if initial support implements only environment delivery.

Future sinks:

- stdin;
- named pipe handoff;
- tightly ACLed temporary file for tools that require file input;
- localhost capability token for local proxy workflows.

Policy packs should be able to choose or forbid sinks per CLI and action class.

## Security Claims

Initial support claims:

- secrets are delivered only after policy evaluation and approval/grant checks;
- secrets are delivered only to a newly launched child process;
- persistent plaintext environment and `.env` writes are avoided;
- command-line arguments do not contain secret values;
- audit records do not contain raw secret values;
- broker-owned storage is protected at rest with DPAPI;
- IPC is local, versioned, authenticated to the current user context, and
  fail-closed.

Initial support does not claim:

- protection from local admin or kernel compromise;
- protection from a malicious approved target binary;
- protection from a same-user debugger or process with enough rights to inspect
  the child;
- that environment variables are the strongest possible delivery mechanism;
- that DPAPI provides runtime user presence.

## Architecture Decision Records

Before implementation starts, capture the initial Windows decisions as ADRs rather
than leaving them only in this plan. Each ADR should state the context,
decision, alternatives considered, security consequences, operational
consequences, and what evidence would cause the decision to be revisited.

Required ADRs:

- Rust for the Windows secret-bearing runtime, with C# reserved for future UI
  and non-secret installer/repair workflows.
- Separate Windows implementation under `platform/windows/` with shared
  contracts, fixtures, and tests instead of a premature shared Rust core.
- Windows 11 as the supported baseline.
- Per-user broker instead of a `LocalSystem` Windows service.
- DPAPI-protected broker-owned file store instead of Credential Manager as the
  primary source of truth.
- Local named pipe IPC with ACLs, caller identity checks, typed messages,
  nonce/TTL replay protection, and fail-closed protocol handling.
- Environment delivery through `CreateProcessW` with an explicit sanitized
  Unicode environment block as a compatibility-mode sink.
- `DeliverySink` abstraction for future stdin, named pipe, temporary-file, and
  local-proxy-token delivery modes.

Future UI ADRs:

- Avalonia, using the latest stable release available at implementation time,
  for a shared Windows/Linux desktop UI when Linux desktop support is in scope.
- UI outside the secret authority, with broker-owned Rust processes retaining
  secret storage, policy evaluation, approval enforcement, and process launch.
- WinUI 3 as the alternative if Windows-only native UI becomes the goal instead
  of Windows/Linux UI reuse.
- Tauri not preferred for approval and security-sensitive management UI because
  it adds webview, frontend supply-chain, content security policy, and XSS-class
  concerns to a product whose UI should stay boring and native-feeling.

The ADRs should link back to this document and to the relevant threat model
updates. When a decision affects a security claim, the ADR must also identify
the matching contract tests or negative tests.

## Acceptance Criteria

- `agentic-secrets run -- <command>` can launch a child process with one
  approved synthetic secret delivered through the environment.
- The child process receives only the intended secret aliases and the minimal
  allowed environment.
- Secret collisions fail closed before process launch.
- Generic runners such as `cmd.exe`, `powershell.exe`, `python.exe`, and
  `node.exe` require an explicit policy pack before raw environment delivery is
  allowed.
- Broker audit records contain decision metadata and no raw secret values.
- Tampering with broker store integrity, rollback anchors, or request nonces
  blocks delivery.
- Named pipe requests from a different user context are rejected.
- Target executable path and identity changes fail closed before secret
  delivery.
- Contract tests cover happy path, denial, stale nonce, malformed IPC,
  rollback lock, env collision, and audit redaction.

## Research References

Primary Windows APIs and references:

- `CreateProcessW` and explicit environment blocks:
  <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw>
- Windows process environment variables:
  <https://learn.microsoft.com/en-us/windows/win32/procthread/environment-variables>
- DPAPI `CryptProtectData`:
  <https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata>
- CNG DPAPI / DPAPI-NG:
  <https://learn.microsoft.com/en-us/windows/win32/seccng/cng-dpapi>
- Named pipe security:
  <https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights>
- Named pipe impersonation:
  <https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-impersonatenamedpipeclient>
- Windows Job Objects:
  <https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects>
- Rust for Windows:
  <https://learn.microsoft.com/en-us/windows/dev-environment/rust/rust-for-windows>
- Avalonia package:
  <https://www.nuget.org/packages/Avalonia>
- Avalonia releases:
  <https://github.com/AvaloniaUI/Avalonia/releases>
- Avalonia documentation:
  <https://docs.avaloniaui.net/docs/welcome>

Related tools and research references:

- 1Password CLI environment injection:
  <https://www.1password.dev/cli/secrets-environment-variables>
- Doppler CLI:
  <https://docs.doppler.com/docs/cli>
- Infisical CLI run:
  <https://infisical.com/docs/cli/commands/run>
- GhostPack SharpDPAPI:
  <https://github.com/GhostPack/SharpDPAPI>

SharpDPAPI is a research and negative-test reference only. It must not be
bundled, invoked by normal runtime flows, or treated as the Windows
secret-delivery implementation.
