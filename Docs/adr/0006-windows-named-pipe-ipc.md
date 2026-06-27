# ADR 0006: User-Scoped Named Pipe IPC

## Status

Accepted for the Windows support plan.

## Context

The broker and runner need local IPC that can bind requests to a user context
and expected runner identity. Pipe names are not secret and default pipe
security is too broad for a secret-delivery authority.

## Decision

Use `\\.\pipe\agentic-secrets\<user-sid>\broker` with an explicit ACL for the
current user SID and required system accounts. Every request carries protocol
version, nonce, timestamp, operation, and typed payload. The broker rejects
unsupported versions, stale or replayed nonces, user SID mismatches, and runner
identity mismatches.

## Alternatives Considered

- TCP localhost: rejected initially because named pipes provide local Windows
  identity and ACL primitives.
- Anonymous inherited handles: rejected because they complicate broker lifecycle
  and user-visible diagnostics.

## Consequences

- IPC authorization remains fail-closed and testable outside the serving loop.
- The Windows serving adapter must later wire observed pipe client process/token
  evidence into the portable authorizer.

## Evidence

- `platform/windows/crates/agentic-secrets-win-ipc/src/lib.rs`
- `platform/windows/tests/named_pipe_auth_contracts.rs`
