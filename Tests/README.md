# Tests

This environment's Swift toolchain does not expose `Testing` or `XCTest`, so AgenticSecrets uses a framework-free contract-test executable:

```sh
swift run agentic-secrets-contract-tests
```

The runner exits nonzero on failure and covers the release-gate invariants from the V4 plan.

Current coverage focuses on security-relevant contracts:

- dynamic command policy pack verification: signature, trusted key id, expiry, publisher/CLI allowlists, duplicate rules, misleading read-only rules, rollback rejection
- adapter classification: built-in registry, unknown flags, context invalidators, generic runner denial
- invocation handles: single use, binding mismatch, TTL/use caps
- leak prevention: env scrubbing, redaction corpus, safe/unsafe audit events
- API session profile enforcement: token, method, path, expiry, redirect origin
- Bitwarden provider restrictions: exact alias, sink binding, expiry, list/project denial
- MCP bridge: session id propagation, invalid session id, path pinning, redirect origin
- rollback lockout and remembered lease scope
- config round-trip and macOS Tahoe SDK/runtime compatibility model
- target assessment hashing and writable-parent rejection

Windows Rust contracts live under `platform/windows/`:

```sh
cd platform/windows
cargo test --workspace
```

They cover environment delivery, named pipe authorization contracts, and
DPAPI-style store integrity with portable fakes for non-Windows CI.
