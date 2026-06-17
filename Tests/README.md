# Tests

This environment's Swift toolchain does not expose `Testing` or `XCTest`, so AgenticFortress uses a framework-free contract-test executable:

```sh
swift run agentic-fortress-contract-tests
```

The runner exits nonzero on failure and covers the release-gate invariants from the V4 plan.

Current coverage focuses on security-relevant contracts:

- dynamic adapter pack verification: signature, trusted key id, expiry, publisher/CLI allowlists, duplicate rules, misleading read-only rules, rollback rejection
- adapter classification: built-in registry, unknown flags, context invalidators, generic runner denial
- invocation handles: single use, binding mismatch, TTL/use caps
- leak prevention: env scrubbing, redaction corpus, safe/unsafe audit events
- proxy profile enforcement: token, method, path, expiry, redirect origin
- BWS provider restrictions: exact alias, sink binding, expiry, list/project denial
- MCP bridge: session id propagation, invalid session id, path pinning, redirect origin
- rollback lockout and remembered lease scope
- config round-trip and macOS Tahoe SDK/runtime compatibility model
- target assessment hashing and writable-parent rejection
