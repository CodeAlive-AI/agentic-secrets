# AgenticFortress V4 Implementation Map

This repository implements the V4 plan as enforceable delivery contracts.

| Plan area | Implementation |
| --- | --- |
| Bounded profiles | `BoundedSafetyProfiles`, `DeliveryClaim` |
| Hard invariants | `AgenticFortressInvariant`, `ReleaseGate`, contract runner |
| Decision manifest | `DecisionManifestFactory` |
| Command adapters | `AdapterPackPayload`, `SignedAdapterPack`, `AdapterPackVerifier`, `AdapterRegistry`, `DynamicCommandAdapter`, `BuiltInAdapterPacks`, `CommandClassifier` |
| TOCTOU tiers | `TargetAssessor`, `TOCTOUTier`, `SealedTargetCache` |
| Shim model | `agentic-fortress-shim`, `EnvironmentScrubber`, `InvocationHandleStore` |
| Generic runner denial | `CommandClassifier`, `PolicyEngine` |
| Local API proxy | `ProxyProfile`, `ProxyAuthorizer`, `agentic-fortress-proxyd` |
| BWS provider split | `BWSProviderPolicy`, `BWSInvocation`, `agentic-fortress-bwsd` |
| Remote MCP bridge | `MCPBridgeSession`, `MCPConformanceSuite`, `agentic-fortress-mcpd` |
| Rollback recovery | `RollbackProtector`, `RecoveryBundle` |
| Audit and redaction | `AuditLog`, `Redactor` |
| Remote delivery claims | `RemoteDeliveryCatalog` |
| Release gates | `agentic-fortress-contract-tests`, `scripts/ci.sh` |
| macOS package/signing scaffolding | `packaging/AgenticFortress.entitlements`, `scripts/package_release.sh`, `scripts/inspect_signing.sh` |
| Configuration | `AgenticFortressConfig`, `config/default.agentic-fortress.json`, `agentic-fortress default-config` |
| Tahoe compatibility | `MacOSCompatibility`, `agentic-fortress check-macos`, `scripts/tahoe_compatibility_check.sh` |
| Threat model and operations | `Docs/THREAT_MODEL.md`, `Docs/OPERATIONS.md` |

Dynamic adapter boundary:

- Built-in adapters are data packs, not special-case parser classes.
- External packs must verify with P-256 signature, trusted key id, publisher allowlist, CLI allowlist, schema version, expiry, and rule validation.
- Adapter rollback is rejected by registry state.
- Lease scope includes adapter id, version, and hash, so adapter changes invalidate approvals.
- Unknown flags and unknown commands fail into high-risk classifications.

Production packaging still needs signed/notarized macOS distribution, XPC listener wiring, and Keychain access-control prompts. Those pieces are platform packaging and TCB integration work; the core release-gate behavior is represented in code and runnable without secrets.
