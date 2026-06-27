# ADR 0004: Per-User Broker Instead Of LocalSystem Service

## Status

Accepted for the Windows support plan.

## Context

Initial Windows support protects a developer user's runtime secret delivery boundary. Running as
`LocalSystem` would increase blast radius, require service installation, and
create a broader token and IPC threat model.

## Decision

Run the Windows broker as a per-user process. Use a user-scoped named
pipe and current-user storage.

## Alternatives Considered

- `LocalSystem` Windows service: deferred until there is an enterprise
  deployment need and a separate threat model.
- Runner-only implementation: rejected because the runner must not own
  production secret storage.

## Consequences

- Initial support avoids privileged service installation.
- IPC authorization is scoped to the current user SID and expected runner
  identity.
- Enterprise deployment remains future work.

## Evidence

- `platform/windows/crates/agentic-secrets-win-ipc/src/lib.rs`
- `platform/windows/tests/named_pipe_auth_contracts.rs`
