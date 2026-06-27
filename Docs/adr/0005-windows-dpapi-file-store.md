# ADR 0005: Broker-Owned DPAPI File Store

## Status

Accepted for the Windows support plan.

## Context

Agentic Secrets needs versioned policy, audit, rollback, and integrity metadata
around secret material. Credential Manager is useful for some app integration
cases, but it is not a complete policy and rollback store.

## Decision

Use a broker-owned DPAPI-protected file store initially. Wrap records in an
integrity envelope and reject rollback epochs. Track DPAPI-NG/CNG DPAPI for
future enterprise/domain-bound scenarios.

## Alternatives Considered

- Credential Manager as source of truth: rejected initially because it does not own
  Agentic Secrets policy and audit envelopes.
- Plain encrypted file without DPAPI: rejected because Windows already provides
  logon-context at-rest protection.

## Consequences

- DPAPI protects at rest under the Windows logon context.
- Runtime approval semantics remain Agentic Secrets responsibility.
- Windows 11 testing must verify `CryptProtectData`/`CryptUnprotectData`.

## Evidence

- `platform/windows/crates/agentic-secrets-win-store/src/lib.rs`
- `platform/windows/crates/agentic-secrets-win-store/src/dpapi.rs`
- `platform/windows/tests/dpapi_store_contracts.rs`
