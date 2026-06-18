import CryptoKit
import Foundation

public enum AdapterRisk: String, Codable, Equatable, Sendable {
    case readOnly = "read-only"
    case mutating
    case destructive
    case unknown

    public var riskLevel: RiskLevel {
        switch self {
        case .readOnly: .readOnly
        case .mutating: .mutating
        case .destructive: .destructive
        case .unknown: .unknown
        }
    }
}

public struct AdapterGlobalFlag: Codable, Equatable, Sendable {
    public enum ValueMode: String, Codable, Sendable {
        case none
        case required
        case equalsOrRequired = "equals-or-required"
    }

    public var names: [String]
    public var normalizedName: String
    public var valueMode: ValueMode
    public var invalidatesLease: Bool
    public var warning: String?

    public init(names: [String], normalizedName: String, valueMode: ValueMode, invalidatesLease: Bool = false, warning: String? = nil) {
        self.names = names
        self.normalizedName = normalizedName
        self.valueMode = valueMode
        self.invalidatesLease = invalidatesLease
        self.warning = warning
    }
}

public struct AdapterRule: Codable, Equatable, Sendable {
    public var resource: String
    public var verb: String
    public var risk: AdapterRisk
    public var confidence: ClassificationConfidence
    public var actionClass: String?
    public var warnings: [String]
    public var leaseInvalidators: [String]

    public init(resource: String, verb: String, risk: AdapterRisk, confidence: ClassificationConfidence = .adapterTested, actionClass: String? = nil, warnings: [String] = [], leaseInvalidators: [String] = []) {
        self.resource = resource
        self.verb = verb
        self.risk = risk
        self.confidence = confidence
        self.actionClass = actionClass
        self.warnings = warnings
        self.leaseInvalidators = leaseInvalidators
    }
}

public struct CommandPolicyPackPayload: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var policyPackID: String
    public var policyPackVersion: Int
    public var cliName: String
    public var supportedCLIVersions: [String]
    public var publisher: String
    public var issuedAt: Date
    public var expiresAt: Date?
    public var globalFlags: [AdapterGlobalFlag]
    public var rules: [AdapterRule]
    public var unknownFlagBehavior: AdapterRisk
    public var defaultRisk: AdapterRisk
    public var defaultWarning: String

    public init(schemaVersion: Int = 1, policyPackID: String, policyPackVersion: Int, cliName: String, supportedCLIVersions: [String] = [], publisher: String, issuedAt: Date = Date(timeIntervalSince1970: 0), expiresAt: Date? = nil, globalFlags: [AdapterGlobalFlag] = [], rules: [AdapterRule], unknownFlagBehavior: AdapterRisk = .unknown, defaultRisk: AdapterRisk = .unknown, defaultWarning: String) {
        self.schemaVersion = schemaVersion
        self.policyPackID = policyPackID
        self.policyPackVersion = policyPackVersion
        self.cliName = cliName
        self.supportedCLIVersions = supportedCLIVersions
        self.publisher = publisher
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.globalFlags = globalFlags
        self.rules = rules
        self.unknownFlagBehavior = unknownFlagBehavior
        self.defaultRisk = defaultRisk
        self.defaultWarning = defaultWarning
    }
}

public struct SignedCommandPolicyPack: Codable, Equatable, Sendable {
    public var payload: CommandPolicyPackPayload
    public var signatureBase64: String
    public var keyID: String

    public init(payload: CommandPolicyPackPayload, signatureBase64: String, keyID: String) {
        self.payload = payload
        self.signatureBase64 = signatureBase64
        self.keyID = keyID
    }
}

public enum CommandPolicyPackError: Error, Equatable {
    case unsupportedSchema(Int)
    case expired
    case untrustedKey(String)
    case invalidSignature
    case publisherNotAllowed(String)
    case cliNotAllowed(String)
    case invalidRule(String)
    case rollback(policyPackID: String, currentVersion: Int, incomingVersion: Int)
}

public struct CommandPolicyPackVerifier: Sendable {
    public var trustedPublicKeys: [String: P256.Signing.PublicKey]
    public var allowedPublishers: Set<String>
    public var allowedCLIs: Set<String>
    public var maxValidity: TimeInterval

    public init(trustedPublicKeys: [String: P256.Signing.PublicKey], allowedPublishers: Set<String>, allowedCLIs: Set<String>, maxValidity: TimeInterval = 366 * 24 * 3600) {
        self.trustedPublicKeys = trustedPublicKeys
        self.allowedPublishers = allowedPublishers
        self.allowedCLIs = allowedCLIs
        self.maxValidity = maxValidity
    }

    public func verify(_ pack: SignedCommandPolicyPack, now: Date = Date()) throws -> CommandPolicyPackPayload {
        guard pack.payload.schemaVersion == 1 else {
            throw CommandPolicyPackError.unsupportedSchema(pack.payload.schemaVersion)
        }
        guard let key = trustedPublicKeys[pack.keyID] else {
            throw CommandPolicyPackError.untrustedKey(pack.keyID)
        }
        guard let signatureData = Data(base64Encoded: pack.signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              key.isValidSignature(signature, for: AdapterCanonicalizer.canonicalData(pack.payload)) else {
            throw CommandPolicyPackError.invalidSignature
        }
        if let expiresAt = pack.payload.expiresAt {
            guard expiresAt >= now, expiresAt.timeIntervalSince(pack.payload.issuedAt) <= maxValidity else {
                throw CommandPolicyPackError.expired
            }
        }
        guard allowedPublishers.contains(pack.payload.publisher) else {
            throw CommandPolicyPackError.publisherNotAllowed(pack.payload.publisher)
        }
        guard allowedCLIs.isEmpty || allowedCLIs.contains(pack.payload.cliName) else {
            throw CommandPolicyPackError.cliNotAllowed(pack.payload.cliName)
        }
        try validateRules(pack.payload)
        return pack.payload
    }

    private func validateRules(_ payload: CommandPolicyPackPayload) throws {
        var seen = Set<String>()
        for rule in payload.rules {
            guard !rule.resource.isEmpty, !rule.verb.isEmpty else {
                throw CommandPolicyPackError.invalidRule("empty resource or verb")
            }
            let key = "\(rule.resource)\u{1f}\(rule.verb)"
            guard seen.insert(key).inserted else {
                throw CommandPolicyPackError.invalidRule("duplicate rule \(rule.resource) \(rule.verb)")
            }
            if rule.risk == .readOnly {
                guard rule.actionClass?.contains("delete") != true, rule.actionClass?.contains("destroy") != true else {
                    throw CommandPolicyPackError.invalidRule("read-only destructive-looking action class")
                }
            }
        }
    }
}

public enum AdapterCanonicalizer {
    public static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try! encoder.encode(value)
    }

    public static func hash<T: Encodable>(_ value: T) -> String {
        let digest = SHA256.hash(data: canonicalData(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct DynamicCommandPolicyAdapter: CommandAdapter {
    public let payload: CommandPolicyPackPayload
    public let policyPackHash: String

    public var cliName: String { payload.cliName }
    public var policyPackVersion: Int { payload.policyPackVersion }

    public init(payload: CommandPolicyPackPayload) {
        self.payload = payload
        self.policyPackHash = AdapterCanonicalizer.hash(payload)
    }

    public func classify(arguments rawArguments: [String], observedVersion: String? = nil) -> NormalizedCommand {
        var arguments = rawArguments
        if arguments.first == payload.cliName {
            arguments.removeFirst()
        }

        var globalFlags: [String: String] = [:]
        var warnings: [String] = []
        var leaseInvalidators: [String] = []
        var positional: [String] = []
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            if let parsed = parseKnownFlag(token: token, arguments: arguments, index: index) {
                globalFlags[parsed.flag.normalizedName] = parsed.value
                if parsed.flag.invalidatesLease {
                    leaseInvalidators.append(parsed.flag.normalizedName)
                }
                if let warning = parsed.flag.warning {
                    warnings.append(warning)
                }
                index = parsed.nextIndex
                continue
            }
            if token.hasPrefix("-") {
                if positional.count < 2 {
                    warnings.append("Unknown flag \(token) makes classification high-risk.")
                    leaseInvalidators.append("unknown-flag")
                }
                positional.append(token)
                index += 1
                continue
            }
            positional.append(token)
            index += 1
        }

        let resource = positional.first ?? "unknown"
        let verb = positional.dropFirst().first ?? "unknown"
        let rest = Array(positional.dropFirst(2))
        let canonical = [payload.cliName, resource, verb] + rest
        let identity = AdapterIdentity(policyPackID: payload.policyPackID, policyPackVersion: payload.policyPackVersion, policyPackHash: policyPackHash, publisher: payload.publisher)

        if warnings.contains(where: { $0.hasPrefix("Unknown flag") }) {
            return make(resource: resource, verb: verb, arguments: rest, globalFlags: globalFlags, risk: payload.unknownFlagBehavior.riskLevel, confidence: .highRisk, warnings: warnings, canonical: canonical, observedVersion: observedVersion, leaseInvalidators: leaseInvalidators, identity: identity)
        }

        if let rule = payload.rules.first(where: { ($0.resource == resource || $0.resource == "*") && $0.verb == verb }) {
            return make(resource: resource, verb: verb, arguments: rest, globalFlags: globalFlags, actionClass: rule.actionClass, risk: rule.risk.riskLevel, confidence: rule.confidence, warnings: warnings + rule.warnings, canonical: canonical, observedVersion: observedVersion, leaseInvalidators: leaseInvalidators + rule.leaseInvalidators, identity: identity)
        }

        return make(resource: resource, verb: verb, arguments: rest, globalFlags: globalFlags, risk: payload.defaultRisk.riskLevel, confidence: .highRisk, warnings: warnings + [payload.defaultWarning], canonical: canonical, observedVersion: observedVersion, leaseInvalidators: leaseInvalidators, identity: identity)
    }

    private func parseKnownFlag(token: String, arguments: [String], index: Int) -> (flag: AdapterGlobalFlag, value: String, nextIndex: Int)? {
        for flag in payload.globalFlags {
            for name in flag.names {
                switch flag.valueMode {
                case .none:
                    if token == name {
                        return (flag, "true", index + 1)
                    }
                case .required:
                    if token == name, index + 1 < arguments.count {
                        return (flag, arguments[index + 1], index + 2)
                    }
                case .equalsOrRequired:
                    if token == name, index + 1 < arguments.count {
                        return (flag, arguments[index + 1], index + 2)
                    }
                    if token.hasPrefix("\(name)=") {
                        return (flag, String(token.dropFirst(name.count + 1)), index + 1)
                    }
                }
            }
        }
        return nil
    }

    private func make(resource: String, verb: String, arguments: [String], globalFlags: [String: String], actionClass: String? = nil, risk: RiskLevel, confidence: ClassificationConfidence, warnings: [String], canonical: [String], observedVersion: String?, leaseInvalidators: [String], identity: AdapterIdentity) -> NormalizedCommand {
        NormalizedCommand(
            cli: payload.cliName,
            version: observedVersion,
            adapterIdentity: identity,
            resource: resource,
            verb: verb,
            arguments: arguments,
            globalFlags: globalFlags,
            actionClass: actionClass ?? "\(payload.cliName).\(resource).\(verb)",
            risk: risk,
            confidence: confidence,
            warnings: Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings,
            canonicalCommand: canonical,
            leaseInvalidators: Array(NSOrderedSet(array: leaseInvalidators)) as? [String] ?? leaseInvalidators
        )
    }
}

public struct PolicyPackRegistry: Sendable {
    public var policyPacks: [any CommandAdapter]
    private var installedVersions: [String: Int]

    public init(policyPacks: [any CommandAdapter] = []) {
        self.policyPacks = policyPacks
        self.installedVersions = Dictionary(uniqueKeysWithValues: policyPacks.map { ($0.cliName, $0.policyPackVersion) })
    }

    public mutating func installVerified(payload: CommandPolicyPackPayload) throws {
        if let current = installedVersions[payload.policyPackID], payload.policyPackVersion < current {
            throw CommandPolicyPackError.rollback(policyPackID: payload.policyPackID, currentVersion: current, incomingVersion: payload.policyPackVersion)
        }
        policyPacks.removeAll { $0.cliName == payload.cliName }
        policyPacks.append(DynamicCommandPolicyAdapter(payload: payload))
        installedVersions[payload.policyPackID] = payload.policyPackVersion
    }
}

public struct PolicyPackRegistryEntry: Codable, Equatable, Sendable {
    public var payload: CommandPolicyPackPayload
    public var policyPackHash: String
    public var installedAt: Date
    public var revokedAt: Date?

    public init(payload: CommandPolicyPackPayload, policyPackHash: String = "", installedAt: Date = Date(), revokedAt: Date? = nil) {
        self.payload = payload
        self.policyPackHash = policyPackHash.isEmpty ? AdapterCanonicalizer.hash(payload) : policyPackHash
        self.installedAt = installedAt
        self.revokedAt = revokedAt
    }
}

public struct PolicyPackRegistryDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entries: [PolicyPackRegistryEntry]

    public init(schemaVersion: Int = 1, entries: [PolicyPackRegistryEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

public enum PolicyPackRegistryStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case missingAdapter(String)
}

public struct PolicyPackRegistryStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func loadDocument() throws -> PolicyPackRegistryDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PolicyPackRegistryDocument()
        }
        let document = try JSONDecoder().decode(PolicyPackRegistryDocument.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else {
            throw PolicyPackRegistryStoreError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    public func saveDocument(_ document: PolicyPackRegistryDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(document).write(to: url, options: [.atomic])
    }

    public func install(payload: CommandPolicyPackPayload, now: Date = Date()) throws {
        var document = try loadDocument()
        document.entries.removeAll { $0.payload.policyPackID == payload.policyPackID }
        document.entries.append(PolicyPackRegistryEntry(payload: payload, installedAt: now))
        try saveDocument(document)
    }

    public func revoke(policyPackID: String, now: Date = Date()) throws {
        var document = try loadDocument()
        guard let index = document.entries.firstIndex(where: { $0.payload.policyPackID == policyPackID }) else {
            throw PolicyPackRegistryStoreError.missingAdapter(policyPackID)
        }
        document.entries[index].revokedAt = now
        try saveDocument(document)
    }

    public func activeRegistry() throws -> PolicyPackRegistry {
        var registry = PolicyPackRegistry()
        for entry in try loadDocument().entries where entry.revokedAt == nil {
            try registry.installVerified(payload: entry.payload)
        }
        return registry
    }
}

public struct PolicyPackGoldenFixture: Codable, Equatable, Sendable {
    public var executableName: String
    public var arguments: [String]
    public var expectedRisk: RiskLevel
    public var expectedActionClass: String

    public init(executableName: String, arguments: [String], expectedRisk: RiskLevel, expectedActionClass: String) {
        self.executableName = executableName
        self.arguments = arguments
        self.expectedRisk = expectedRisk
        self.expectedActionClass = expectedActionClass
    }
}

public enum PolicyPackGoldenFixtureError: Error, Equatable {
    case mismatch(expected: PolicyPackGoldenFixture, actualRisk: RiskLevel, actualActionClass: String)
}

public enum PolicyPackGoldenFixtureRunner {
    public static func run(fixtures: [PolicyPackGoldenFixture], registry: PolicyPackRegistry) throws {
        let classifier = CommandClassifier(registry: registry)
        for fixture in fixtures {
            let command = classifier.classify(executableName: fixture.executableName, arguments: fixture.arguments)
            guard command.risk == fixture.expectedRisk, command.actionClass == fixture.expectedActionClass else {
                throw PolicyPackGoldenFixtureError.mismatch(expected: fixture, actualRisk: command.risk, actualActionClass: command.actionClass)
            }
        }
    }
}

public enum BuiltInPolicyPacks {
    public static func registry() -> PolicyPackRegistry {
        var registry = PolicyPackRegistry()
        try! registry.installVerified(payload: hcloud)
        try! registry.installVerified(payload: githubCLI)
        try! registry.installVerified(payload: terraform)
        return registry
    }

    public static let hcloud = CommandPolicyPackPayload(
        policyPackID: "com.agenticsecrets.policyPacks.hcloud",
        policyPackVersion: 1,
        cliName: "hcloud",
        supportedCLIVersions: ["1.*"],
        publisher: "AgenticSecrets Builtins",
        globalFlags: [
            .init(names: ["--context"], normalizedName: "context", valueMode: .equalsOrRequired),
            .init(names: ["--config"], normalizedName: "config", valueMode: .equalsOrRequired, invalidatesLease: true, warning: "Custom config changes auth/context; remembered leases must not apply."),
            .init(names: ["--debug", "--json", "-o=json"], normalizedName: "format/debug", valueMode: .none)
        ],
        rules: hcloudReadOnly.map { AdapterRule(resource: $0.0, verb: $0.1, risk: .readOnly) }
            + ["delete", "destroy", "rebuild", "poweroff", "shutdown", "disable-protection", "disable-backup"].map { AdapterRule(resource: "*", verb: $0, risk: .destructive, confidence: .highRisk) },
        defaultRisk: .mutating,
        defaultWarning: "Unknown hcloud command requires one-time approval and no remembered lease."
    )

    public static let githubCLI = CommandPolicyPackPayload(
        policyPackID: "com.agenticsecrets.policyPacks.gh",
        policyPackVersion: 1,
        cliName: "gh",
        supportedCLIVersions: ["2.*"],
        publisher: "AgenticSecrets Builtins",
        globalFlags: [
            .init(names: ["--hostname"], normalizedName: "hostname", valueMode: .equalsOrRequired, invalidatesLease: true, warning: "Hostname changes GitHub auth/context; remembered leases must not apply."),
            .init(names: ["--repo", "-R"], normalizedName: "repo", valueMode: .equalsOrRequired, invalidatesLease: true, warning: "Repository changes command context; remembered leases must not apply.")
        ],
        rules: [
            .init(resource: "auth", verb: "status", risk: .readOnly),
            .init(resource: "repo", verb: "view", risk: .readOnly),
            .init(resource: "issue", verb: "list", risk: .readOnly),
            .init(resource: "issue", verb: "view", risk: .readOnly),
            .init(resource: "pr", verb: "list", risk: .readOnly),
            .init(resource: "pr", verb: "view", risk: .readOnly),
            .init(resource: "repo", verb: "delete", risk: .destructive, confidence: .highRisk),
            .init(resource: "release", verb: "delete", risk: .destructive, confidence: .highRisk)
        ],
        defaultRisk: .mutating,
        defaultWarning: "Unknown gh command requires one-time approval and no remembered lease."
    )

    public static let terraform = CommandPolicyPackPayload(
        policyPackID: "com.agenticsecrets.policyPacks.terraform",
        policyPackVersion: 0,
        cliName: "terraform",
        supportedCLIVersions: [],
        publisher: "AgenticSecrets Builtins",
        rules: [
            .init(resource: "terraform", verb: "destroy", risk: .destructive, confidence: .highRisk)
        ],
        defaultRisk: .unknown,
        defaultWarning: "Terraform is plugin/state/back-end dependent; raw env secret delivery is denied by default."
    )

    private static let hcloudReadOnly: [(String, String)] = [
        ("datacenter", "list"), ("datacenter", "describe"),
        ("location", "list"), ("location", "describe"),
        ("server-type", "list"), ("server-type", "describe"),
        ("image", "list"), ("image", "describe"),
        ("iso", "list"), ("iso", "describe"),
        ("server", "list"), ("server", "describe"), ("server", "ip"), ("server", "metrics"),
        ("network", "list"), ("network", "describe"),
        ("firewall", "list"), ("firewall", "describe"),
        ("ssh-key", "list"), ("ssh-key", "describe"),
        ("volume", "list"), ("volume", "describe"),
        ("load-balancer", "list"), ("load-balancer", "describe"),
        ("primary-ip", "list"), ("primary-ip", "describe"),
        ("floating-ip", "list"), ("floating-ip", "describe"),
        ("placement-group", "list"), ("placement-group", "describe"),
        ("zone", "list"), ("zone", "describe")
    ]
}
