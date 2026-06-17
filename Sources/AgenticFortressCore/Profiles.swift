import Foundation

public enum DeliveryFlow: String, Codable, CaseIterable, Sendable {
    case cliEnv = "cli-env"
    case apiProxy = "api-proxy"
    case bwsProvider = "bws-provider"
    case remoteMCP = "remote-mcp"
    case remoteSSHStdin = "remote-ssh-stdin"
    case cloudNativeIdentity = "cloud-native-identity"
}

public enum DeliveryMode: String, Codable, Sendable {
    case env
    case proxy
    case stdin
    case tokenFile = "token-file"
    case mcpHeader = "mcp-header"
    case providerFetch = "provider-fetch"
    case cloudIdentity = "cloud-identity"
}

public struct DeliveryClaim: Codable, Equatable, Sendable {
    public var profile: DeliveryFlow
    public var claim: String
    public var nonClaims: [String]
    public var tcb: [String]

    public init(profile: DeliveryFlow, claim: String, nonClaims: [String], tcb: [String]) {
        self.profile = profile
        self.claim = claim
        self.nonClaims = nonClaims
        self.tcb = tcb
    }
}

public enum BoundedSafetyProfiles {
    public static let all: [DeliveryClaim] = [
        DeliveryClaim(
            profile: .cliEnv,
            claim: "Secret is not stored in .env, shell profiles, shell history, ambient shell environment, or MCP client configs; it is delivered only through signed shim intent to an approved target command.",
            nonClaims: [
                "Does not make the target CLI trustworthy.",
                "Does not prevent child processes from inheriting an approved environment variable.",
                "Does not defend against root or kernel compromise."
            ],
            tcb: ["agentic-fortress-shim", "agentic-fortressd-core", "Keychain", "approved target CLI"]
        ),
        DeliveryClaim(
            profile: .apiProxy,
            claim: "Development app receives only a local proxy endpoint and per-session proxy token; the real upstream API key stays in agentic-fortress-proxyd/provider path.",
            nonClaims: [
                "A localhost proxy token is still a local bearer capability.",
                "Does not hide API use from all same-user local attackers."
            ],
            tcb: ["agentic-fortress-proxyd", "agentic-fortressd-core", "provider helper", "upstream API"]
        ),
        DeliveryClaim(
            profile: .bwsProvider,
            claim: "BWS access token is owned by agentic-fortress-bwsd and is not placed in env, argv, files, logs, MCP configs, or core plaintext state.",
            nonClaims: [
                "BWS machine account blast radius remains equal to its upstream scope.",
                "A compromised provider helper can use approved scope during an active lease."
            ],
            tcb: ["agentic-fortress-bwsd", "BWS SDK/CLI", "Keychain", "agentic-fortressd-core authorization"]
        ),
        DeliveryClaim(
            profile: .remoteMCP,
            claim: "Bearer token is not stored in MCP client config and is injected only by agentic-fortress-mcpd into requests for a pinned upstream profile.",
            nonClaims: [
                "Does not prove remote MCP server safety.",
                "Tool filtering is a guardrail, not a security boundary."
            ],
            tcb: ["agentic-fortress-mcpd", "agentic-fortressd-core", "provider helper", "pinned MCP upstream"]
        )
    ]
}

public enum AgenticFortressInvariant: String, CaseIterable, Codable, Sendable {
    case noPublicGetSecretAPI = "I1.no-public-get-secret-api"
    case allAccessTiedToIntent = "I2.intent-bound-access"
    case opaqueServerSideHandles = "I3.opaque-server-side-handles"
    case handlesBoundToContext = "I4.context-bound-handles"
    case noGeneratedShellShims = "I5.no-generated-shell-shims"
    case untrustedProcessInputs = "I6.untrusted-process-inputs"
    case genericEnvDeniedByDefault = "I7.generic-env-denied-by-default"
    case bwsSingleSecretRuntime = "I8.bws-single-secret-runtime"
    case auditNeverStoresRawSecrets = "I9.redacted-audit"
    case rollbackLocksPolicy = "I10.rollback-locks-policy"
    case mcpPinnedProfileOnly = "I11.mcp-pinned-profile-only"
    case releaseGatesRequired = "I12.release-gates-required"
}

