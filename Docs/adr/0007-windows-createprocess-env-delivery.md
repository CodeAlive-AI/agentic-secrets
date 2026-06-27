# ADR 0007: `CreateProcessW` Environment Delivery

## Status

Accepted for the Windows support plan.

## Context

Initial Windows support needs broad CLI compatibility while avoiding `.env`, shell profile,
persistent user/system environment, argument, registry, and debug-log delivery.
Windows process creation accepts an explicit Unicode environment block.

## Decision

Use `CreateProcessW` with `CREATE_UNICODE_ENVIRONMENT` and an explicit sanitized
environment block. Start from a small allowlist, reject injected-name
collisions, scrub inherited secret-shaped variables, and zeroize runner-side
buffers best-effort after launch. Assign the child to a Job Object for
process-tree accounting.

## Alternatives Considered

- Ambient inheritance plus overrides: rejected because it preserves unrelated
  and potentially secret-shaped variables.
- Command-line arguments: rejected because process arguments are commonly
  inspectable.

## Consequences

- Environment delivery remains a compatibility sink, not a claim that the child
  cannot read or expose the secret.
- Windows 11 verification must cover actual child launch and exit propagation.

## Evidence

- `platform/windows/crates/agentic-secrets-win-contracts/src/environment.rs`
- `platform/windows/crates/agentic-secrets-win-run/src/process.rs`
- `platform/windows/tests/env_delivery_contracts.rs`
