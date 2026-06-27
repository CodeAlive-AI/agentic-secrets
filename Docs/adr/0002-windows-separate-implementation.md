# ADR 0002: Separate Windows Implementation With Shared Contracts

## Status

Accepted for the Windows support plan.

## Context

The current product is Swift/macOS-first. Windows support needs different platform
APIs and trust evidence. Prematurely extracting a shared Rust core would freeze
contracts before both implementations have converged.

## Decision

Keep Windows code under `platform/windows/`. Share behavior first through
schemas, fixtures, and contract tests, not a cross-platform runtime core.

## Alternatives Considered

- Move macOS logic into shared Rust now: rejected because it would expand the
  change surface and blur already-working macOS release gates.
- Duplicate everything without contracts: rejected because security behavior
  would drift silently.

## Consequences

- The macOS Swift package stays intact.
- Windows can evolve independently while matching product-level security
  claims.
- Shared contracts can later justify a common library when stability is proven.

## Evidence

- `platform/windows/Cargo.toml`
- `Docs/contracts/windows-initial.md`
- `platform/windows/tests/`
