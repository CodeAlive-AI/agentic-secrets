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
| Local IPC control plane | `CoreIPCRequest`, `CoreIPCResponse`, `CoreIPCAuthorizer`, `IPCConformanceReport`, `agentic-fortress ipc-conformance` |
| Self-build helper trust | `InstallManifest`, `SelfBuildPeerIdentity`, `SelfBuildPeerValidator`, `scripts/install_local.sh` |
| Generic runner denial | `CommandClassifier`, `PolicyEngine` |
| Local API proxy | `ProxyProfile`, `ProxyAuthorizer`, `agentic-fortress-proxyd` |
| BWS provider split | `BWSProviderPolicy`, `BWSInvocation`, `agentic-fortress-bwsd` |
| Remote MCP bridge | `MCPBridgeSession`, `MCPConformanceSuite`, `agentic-fortress-mcpd` |
| Rollback recovery | `RollbackProtector`, `RecoveryBundle` |
| Audit and redaction | `AuditLog`, `Redactor` |
| Remote delivery claims | `RemoteDeliveryCatalog` |
| Release gates | `agentic-fortress-contract-tests`, `agentic-fortress release-gates`, `scripts/ci.sh` |
| macOS package/signing scaffolding | `packaging/AgenticFortress.entitlements`, `packaging/AgenticFortressCore.entitlements`, `scripts/package_release.sh`, `scripts/install_local.sh`, `scripts/uninstall_local.sh`, `scripts/inspect_signing.sh` |
| Release evidence | `scripts/create_release_evidence.sh` |
| Configuration | `AgenticFortressConfig`, `config/default.agentic-fortress.json`, `agentic-fortress default-config` |
| Tahoe compatibility | `MacOSCompatibility`, `agentic-fortress check-macos`, `scripts/tahoe_compatibility_check.sh` |
| Threat model and operations | `Docs/THREAT_MODEL.md`, `Docs/OPERATIONS.md` |

Dynamic adapter boundary:

- Built-in adapters are data packs, not special-case parser classes.
- External packs must verify with P-256 signature, trusted key id, publisher allowlist, CLI allowlist, schema version, expiry, and rule validation.
- Adapter rollback is rejected by registry state.
- Lease scope includes adapter id, version, and hash, so adapter changes invalidate approvals.
- Unknown flags and unknown commands fail into high-risk classifications.

The default production track is source self-build with local ad-hoc signing. `agentic-fortress release-gates` reports `canRunLocal` independently from optional `canDistributeBinary`, so Developer ID signing and notarization do not block local production use. Future downloadable binary distribution work remains in `Docs/FUTURE_DEVELOPER_ID.md`.
