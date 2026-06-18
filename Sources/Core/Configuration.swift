import Foundation

public struct AgenticFortressConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var adapterTrust: AdapterTrustConfig
    public var commandPolicy: CommandPolicyConfig
    public var deliveryDefaults: DeliveryDefaultsConfig
    public var proxyProfiles: [ProxyProfile]
    public var mcpProfiles: [MCPUpstreamProfile]
    public var bwsBindings: [BWSSecretBinding]
    public var macOSCompatibility: MacOSCompatibilityConfig

    public init(
        schemaVersion: Int = 1,
        adapterTrust: AdapterTrustConfig = .default,
        commandPolicy: CommandPolicyConfig = .default,
        deliveryDefaults: DeliveryDefaultsConfig = .default,
        proxyProfiles: [ProxyProfile] = [BuiltInProxyProfiles.openAI, BuiltInProxyProfiles.anthropic],
        mcpProfiles: [MCPUpstreamProfile] = [],
        bwsBindings: [BWSSecretBinding] = [],
        macOSCompatibility: MacOSCompatibilityConfig = .tahoe
    ) {
        self.schemaVersion = schemaVersion
        self.adapterTrust = adapterTrust
        self.commandPolicy = commandPolicy
        self.deliveryDefaults = deliveryDefaults
        self.proxyProfiles = proxyProfiles
        self.mcpProfiles = mcpProfiles
        self.bwsBindings = bwsBindings
        self.macOSCompatibility = macOSCompatibility
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case adapterTrust
        case commandPolicy
        case deliveryDefaults
        case proxyProfiles
        case mcpProfiles
        case bwsBindings
        case macOSCompatibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.adapterTrust = try container.decode(AdapterTrustConfig.self, forKey: .adapterTrust)
        self.commandPolicy = try container.decodeIfPresent(CommandPolicyConfig.self, forKey: .commandPolicy) ?? .default
        self.deliveryDefaults = try container.decode(DeliveryDefaultsConfig.self, forKey: .deliveryDefaults)
        self.proxyProfiles = try container.decode([ProxyProfile].self, forKey: .proxyProfiles)
        self.mcpProfiles = try container.decode([MCPUpstreamProfile].self, forKey: .mcpProfiles)
        self.bwsBindings = try container.decodeIfPresent([BWSSecretBinding].self, forKey: .bwsBindings) ?? []
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

public struct AdapterTrustConfig: Codable, Equatable, Sendable {
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

    public static let `default` = AdapterTrustConfig(
        allowedPublishers: ["AgenticFortress Builtins"],
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
    public var proxyTokensRequired: Bool
    public var bwsRuntimeSingleSecretOnly: Bool
    public var mcpPinnedProfilesOnly: Bool
    public var maxInvocationHandleTTLSeconds: TimeInterval

    public init(denyRawEnvForGenericRunners: Bool = true, proxyTokensRequired: Bool = true, bwsRuntimeSingleSecretOnly: Bool = true, mcpPinnedProfilesOnly: Bool = true, maxInvocationHandleTTLSeconds: TimeInterval = 30) {
        self.denyRawEnvForGenericRunners = denyRawEnvForGenericRunners
        self.proxyTokensRequired = proxyTokensRequired
        self.bwsRuntimeSingleSecretOnly = bwsRuntimeSingleSecretOnly
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
    public static func load(path: String) throws -> AgenticFortressConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(AgenticFortressConfig.self, from: data)
    }

    public static func encode(_ config: AgenticFortressConfig) throws -> String {
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
