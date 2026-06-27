# ADR 0003: Windows 11 Baseline

## Status

Accepted for the Windows support plan.

## Context

Initial Windows support targets current Windows 11 developer machines. Narrowing the baseline avoids
compatibility work for unsupported or uncommon environments while the security
model is still being proven.

## Decision

Treat Windows 11 as the supported baseline. Windows Server, older Windows
clients, MSI deployment, enterprise service accounts, and domain-bound DPAPI-NG
remain out of initial scope.

## Consequences

- Tests and manual verification should run on Windows 11.
- The per-user broker model is optimized for developer workstations, not fleet
  management.
- Future enterprise support needs its own threat model.

## Evidence

- Windows support plan
- `platform/windows/tests/named_pipe_auth_contracts.rs`
