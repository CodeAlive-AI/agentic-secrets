import Foundation

public struct AgenticSecretsConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var policyPackTrust: PolicyPackTrustConfiguration
    public var commandPolicy: CommandPolicyConfig
    public var deliveryDefaults: DeliveryDefaultsConfig
    public var apiSessionProfiles: [APISessionProfile]
    public var mcpProfiles: [MCPUpstreamProfile]
    public var bitwardenBindings: [BitwardenSecretBinding]
    public var macOSCompatibility: MacOSCompatibilityConfig

    public init(
        schemaVersion: Int = 1,
        policyPackTrust: PolicyPackTrustConfiguration = .default,
        commandPolicy: CommandPolicyConfig = .default,
        deliveryDefaults: DeliveryDefaultsConfig = .default,
        apiSessionProfiles: [APISessionProfile] = [BuiltInAPISessionProfiles.openAI, BuiltInAPISessionProfiles.anthropic],
        mcpProfiles: [MCPUpstreamProfile] = [],
        bitwardenBindings: [BitwardenSecretBinding] = [],
        macOSCompatibility: MacOSCompatibilityConfig = .tahoe
    ) {
        self.schemaVersion = schemaVersion
        self.policyPackTrust = policyPackTrust
        self.commandPolicy = commandPolicy
        self.deliveryDefaults = deliveryDefaults
        self.apiSessionProfiles = apiSessionProfiles
        self.mcpProfiles = mcpProfiles
        self.bitwardenBindings = bitwardenBindings
        self.macOSCompatibility = macOSCompatibility
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case policyPackTrust
        case commandPolicy
        case deliveryDefaults
        case apiSessionProfiles
        case mcpProfiles
        case bitwardenBindings
        case macOSCompatibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.policyPackTrust = try container.decode(PolicyPackTrustConfiguration.self, forKey: .policyPackTrust)
        self.commandPolicy = try container.decodeIfPresent(CommandPolicyConfig.self, forKey: .commandPolicy) ?? .default
        self.deliveryDefaults = try container.decode(DeliveryDefaultsConfig.self, forKey: .deliveryDefaults)
        self.apiSessionProfiles = try container.decode([APISessionProfile].self, forKey: .apiSessionProfiles)
        self.mcpProfiles = try container.decode([MCPUpstreamProfile].self, forKey: .mcpProfiles)
        self.bitwardenBindings = try container.decodeIfPresent([BitwardenSecretBinding].self, forKey: .bitwardenBindings) ?? []
        self.macOSCompatibility = try container.decode(MacOSCompatibilityConfig.self, forKey: .macOSCompatibility)
    }
}

public struct CommandPolicyConfig: Codable, Equatable, Sendable {
    public var destructiveTerms: [String]
    public var forbiddenTerms: [String]

    public init(destructiveTerms: [String] = ["delete", "remove"], forbiddenTerms: [String] = []) {
        self.destructiveTerms = Self.normalizedTerms(destructiveTerms)
        self.forbiddenTerms = Self.normalizedTerms(forbiddenTerms)
    }

    public static let `default` = CommandPolicyConfig()

    public static func normalizedTerms(_ terms: [String]) -> [String] {
        Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }
}

public struct PolicyPackTrustConfiguration: Codable, Equatable, Sendable {
    public var allowedPublishers: Set<String>
    public var allowedCLIs: Set<String>
    public var requireSignatureForExternalPacks: Bool
    public var maxPackValiditySeconds: TimeInterval
    public var rejectAdapterRollback: Bool

    public init(allowedPublishers: Set<String>, allowedCLIs: Set<String>, requireSignatureForExternalPacks: Bool = true, maxPackValiditySeconds: TimeInterval = 366 * 24 * 3600, rejectAdapterRollback: Bool = true) {
        self.allowedPublishers = allowedPublishers
        self.allowedCLIs = allowedCLIs
        self.requireSignatureForExternalPacks = requireSignatureForExternalPacks
        self.maxPackValiditySeconds = maxPackValiditySeconds
        self.rejectAdapterRollback = rejectAdapterRollback
    }

    public static let `default` = PolicyPackTrustConfiguration(
        allowedPublishers: ["AgenticSecrets Builtins"],
        allowedCLIs: ["hcloud", "gh", "terraform"]
    )

    enum CodingKeys: String, CodingKey {
        case allowedPublishers
        case allowedCLIs
        case requireSignatureForExternalPacks
        case maxPackValiditySeconds
        case rejectAdapterRollback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowedPublishers = Set(try container.decode([String].self, forKey: .allowedPublishers))
        self.allowedCLIs = Set(try container.decode([String].self, forKey: .allowedCLIs))
        self.requireSignatureForExternalPacks = try container.decode(Bool.self, forKey: .requireSignatureForExternalPacks)
        self.maxPackValiditySeconds = try container.decode(TimeInterval.self, forKey: .maxPackValiditySeconds)
        self.rejectAdapterRollback = try container.decode(Bool.self, forKey: .rejectAdapterRollback)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allowedPublishers.sorted(), forKey: .allowedPublishers)
        try container.encode(allowedCLIs.sorted(), forKey: .allowedCLIs)
        try container.encode(requireSignatureForExternalPacks, forKey: .requireSignatureForExternalPacks)
        try container.encode(maxPackValiditySeconds, forKey: .maxPackValiditySeconds)
        try container.encode(rejectAdapterRollback, forKey: .rejectAdapterRollback)
    }
}

public struct DeliveryDefaultsConfig: Codable, Equatable, Sendable {
    public var denyRawEnvForGenericRunners: Bool
    public var apiSessionTokensRequired: Bool
    public var bitwardenRuntimeSingleSecretOnly: Bool
    public var mcpPinnedProfilesOnly: Bool
    public var maxInvocationHandleTTLSeconds: TimeInterval

    public init(denyRawEnvForGenericRunners: Bool = true, apiSessionTokensRequired: Bool = true, bitwardenRuntimeSingleSecretOnly: Bool = true, mcpPinnedProfilesOnly: Bool = true, maxInvocationHandleTTLSeconds: TimeInterval = 30) {
        self.denyRawEnvForGenericRunners = denyRawEnvForGenericRunners
        self.apiSessionTokensRequired = apiSessionTokensRequired
        self.bitwardenRuntimeSingleSecretOnly = bitwardenRuntimeSingleSecretOnly
        self.mcpPinnedProfilesOnly = mcpPinnedProfilesOnly
        self.maxInvocationHandleTTLSeconds = maxInvocationHandleTTLSeconds
    }

    public static let `default` = DeliveryDefaultsConfig()
}

public struct MacOSCompatibilityConfig: Codable, Equatable, Sendable {
    public var minimumRuntimeMajor: Int
    public var validatedRuntimeMajor: Int
    public var requiredSDKMajor: Int
    public var requireHardenedRuntime: Bool
    public var requireNotarizationForDistribution: Bool

    public init(minimumRuntimeMajor: Int, validatedRuntimeMajor: Int, requiredSDKMajor: Int, requireHardenedRuntime: Bool = true, requireNotarizationForDistribution: Bool = true) {
        self.minimumRuntimeMajor = minimumRuntimeMajor
        self.validatedRuntimeMajor = validatedRuntimeMajor
        self.requiredSDKMajor = requiredSDKMajor
        self.requireHardenedRuntime = requireHardenedRuntime
        self.requireNotarizationForDistribution = requireNotarizationForDistribution
    }

    public static let tahoe = MacOSCompatibilityConfig(minimumRuntimeMajor: 14, validatedRuntimeMajor: 26, requiredSDKMajor: 26)
}

public enum ConfigurationLoader {
    public static func load(path: String) throws -> AgenticSecretsConfiguration {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(AgenticSecretsConfiguration.self, from: data)
    }

    public static func encode(_ config: AgenticSecretsConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(config), as: UTF8.self)
    }
}

public struct MacOSCompatibilityReport: Codable, Equatable, Sendable {
    public var runtimeMajor: Int
    public var requiredSDKMajor: Int
    public var sdkMajor: Int?
    public var runtimeOK: Bool
    public var sdkOK: Bool?
}

public enum MacOSCompatibility {
    public static func runtimeReport(config: MacOSCompatibilityConfig = .tahoe, sdkMajor: Int? = nil, operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> MacOSCompatibilityReport {
        let runtimeMajor = operatingSystemVersion.majorVersion
        return MacOSCompatibilityReport(
            runtimeMajor: runtimeMajor,
            requiredSDKMajor: config.requiredSDKMajor,
            sdkMajor: sdkMajor,
            runtimeOK: runtimeMajor >= config.minimumRuntimeMajor,
            sdkOK: sdkMajor.map { $0 >= config.requiredSDKMajor }
        )
    }
}
