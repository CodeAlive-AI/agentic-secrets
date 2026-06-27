# ADR 0009: Future Windows/Linux UI Outside Secret Authority

## Status

Accepted as future guidance for the Windows support plan.

## Context

Initial Windows support has no desktop UI. A future Windows/Linux desktop may need shared UI
investment while keeping secret storage, policy evaluation, approval
enforcement, and process launch in Rust broker-owned processes.

## Decision

Prefer Avalonia on the latest stable release available when shared
Windows/Linux UI becomes a near-term product goal. Use WinUI 3 only if the goal
becomes Windows-only native UI. Do not put the UI inside the secret authority.
Do not prefer Tauri for approval and security-sensitive management UI because it
adds webview, frontend supply-chain, CSP, and XSS-class concerns.

## Consequences

- Initial support remains CLI/runtime only.
- UI can display state, diagnostics, approvals, audit, repair flows, and policy
  pack management, but broker-owned Rust processes remain authoritative.

## Evidence

- Windows support plan
