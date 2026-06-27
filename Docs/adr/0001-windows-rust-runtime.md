# ADR 0001: Rust Windows Secret-Bearing Runtime

## Status

Accepted for the Windows support plan.

## Context

Initial Windows support needs DPAPI storage, named pipe IPC, caller identity checks,
`CreateProcessW` environment delivery, and Job Object accounting. These are
secret-bearing paths where buffer lifetime, handle ownership, and fail-closed
interop matter.

Current Microsoft Windows Rust guidance points developers to the `windows` crate
for generated Win32 bindings. The initial implementation follows that model with
small Windows-only adapters and portable contract logic.

## Decision

Use Rust for the Windows broker, runner, IPC, store, and contracts under
`platform/windows/`. Reserve C#/.NET for future non-secret UI or installer work.

## Alternatives Considered

- C#/.NET: useful for future UI, but managed strings and broad Win32 interop in
  the hot path make secret lifetime harder to audit.
- Go: acceptable for experiments, but less direct for Windows security
  descriptors, token checks, Unicode environment blocks, and handle lifetime.

## Consequences

- Secret-bearing code can keep unsafe Win32 interop small and reviewed.
- Cross-platform CI can exercise most policy contracts on macOS/Linux.
- Windows-only launch, DPAPI, and named pipe serving still require Windows 11
  verification before release claims.

## Evidence

- `platform/windows/crates/agentic-secrets-win-run/src/process.rs`
- `platform/windows/crates/agentic-secrets-win-store/src/dpapi.rs`
- `platform/windows/tests/env_delivery_contracts.rs`
- `platform/windows/tests/dpapi_store_contracts.rs`
