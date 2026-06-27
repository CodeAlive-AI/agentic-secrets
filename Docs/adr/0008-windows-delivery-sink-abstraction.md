# ADR 0008: Delivery Sink Abstraction

## Status

Accepted for the Windows support plan.

## Context

Environment variables are the first Windows compatibility sink, but future
tools may need stdin, named pipe handoff, tightly ACLed temporary files, or
localhost capability tokens.

## Decision

Model delivery plans with a `DeliverySinkKind` from the start. Implement only
the environment sink initially.

## Alternatives Considered

- Hard-code environment-only plans: rejected because it would make policy pack
  evolution and future negative tests more expensive.

## Consequences

- Policy can later forbid or choose sinks per CLI/action class.
- Initial tests can assert environment-only behavior without closing future design.

## Evidence

- `platform/windows/crates/agentic-secrets-win-contracts/src/protocol.rs`
- `platform/windows/tests/env_delivery_contracts.rs`
