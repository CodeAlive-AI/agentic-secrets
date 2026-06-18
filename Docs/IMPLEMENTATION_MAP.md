# Agentic Secrets V4 Implementation Map

This repository implements the V4 plan as enforceable delivery contracts.

| Plan area | Implementation |
| --- | --- |
| Bounded profiles | `DeliveryContracts`, `DeliveryContract` |
| Hard invariants | `SecurityInvariant`, `ReleaseGate`, contract runner |
| Decision manifest | `DeliveryDecisionManifestFactory` |
| Command policyPacks | `CommandPolicyPackPayload`, `SignedCommandPolicyPack`, `CommandPolicyPackVerifier`, `PolicyPackRegistry`, `DynamicCommandPolicyAdapter`, `BuiltInPolicyPacks`, `CommandClassifier` |
| TOCTOU tiers | `TargetAssessor`, `TOCTOUTier`, `SealedTargetCache` |
| Shim model | `agentic-secrets-shim`, `EnvironmentScrubber`, `InvocationHandleStore` |
| Local IPC control plane | `BrokerIPCRequest`, `BrokerIPCResponse`, `BrokerIPCAuthorizer`, `IPCConformanceReport`, `agentic-secrets ipc-conformance` |
| Self-build helper trust | `InstallManifest`, `SelfBuildPeerIdentity`, `SelfBuildPeerValidator`, `scripts/install_local.sh` |
| Generic runner denial | `CommandClassifier`, `PolicyEngine` |
| Local API session | `APISessionProfile`, `APISessionAuthorizer`, `agentic-secrets-api-sessiond` |
| Bitwarden provider split | `BitwardenProviderPolicy`, `BitwardenInvocation`, `agentic-secrets-bitwarden-providerd` |
| Remote MCP bridge | `MCPBridgeSession`, `MCPConformanceSuite`, `agentic-secrets-mcpd` |
| Rollback recovery | `RollbackProtector`, `RecoveryBundle` |
| Audit and redaction | `AuditLog`, `Redactor` |
| Remote delivery claims | `RemoteDeliveryCatalog` |
| Release gates | `agentic-secrets-contract-tests`, `agentic-secrets release-gates`, `scripts/ci.sh` |
| macOS package/signing scaffolding | `packaging/AgenticSecrets.entitlements`, `scripts/package_release.sh`, `scripts/install_local.sh`, `scripts/uninstall_local.sh`, `scripts/inspect_signing.sh` |
| Release evidence | `scripts/create_release_evidence.sh` |
| Configuration | `AgenticSecretsConfiguration`, `config/default.agentic-secrets.json`, `agentic-secrets default-config` |
| Tahoe compatibility | `MacOSCompatibility`, `agentic-secrets check-macos`, `scripts/tahoe_compatibility_check.sh` |
| Threat model and operations | `Docs/THREAT_MODEL.md`, `Docs/OPERATIONS.md` |

Dynamic adapter boundary:

- Built-in policyPacks are data packs, not special-case parser classes.
- External packs must verify with P-256 signature, trusted key id, publisher allowlist, CLI allowlist, schema version, expiry, and rule validation.
- Adapter rollback is rejected by registry state.
- Lease scope includes adapter id, version, and hash, so adapter changes invalidate approvals.
- Unknown flags and unknown commands fail into high-risk classifications.

The default production track is source self-build with local ad-hoc signing. `agentic-secrets release-gates` reports `canRunLocal` independently from optional `canDistributeBinary`, so Developer ID signing and notarization do not block local production use. Future downloadable binary distribution work remains in `Docs/FUTURE_DEVELOPER_ID.md`.
