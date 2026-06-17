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

public struct AdapterPackPayload: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var adapterID: String
    public var adapterVersion: Int
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

    public init(schemaVersion: Int = 1, adapterID: String, adapterVersion: Int, cliName: String, supportedCLIVersions: [String] = [], publisher: String, issuedAt: Date = Date(timeIntervalSince1970: 0), expiresAt: Date? = nil, globalFlags: [AdapterGlobalFlag] = [], rules: [AdapterRule], unknownFlagBehavior: AdapterRisk = .unknown, defaultRisk: AdapterRisk = .unknown, defaultWarning: String) {
        self.schemaVersion = schemaVersion
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
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

public struct SignedAdapterPack: Codable, Equatable, Sendable {
    public var payload: AdapterPackPayload
    public var signatureBase64: String
    public var keyID: String

    public init(payload: AdapterPackPayload, signatureBase64: String, keyID: String) {
        self.payload = payload
        self.signatureBase64 = signatureBase64
        self.keyID = keyID
    }
}

public enum AdapterPackError: Error, Equatable {
    case unsupportedSchema(Int)
    case expired
    case untrustedKey(String)
    case invalidSignature
    case publisherNotAllowed(String)
    case cliNotAllowed(String)
    case invalidRule(String)
    case rollback(adapterID: String, currentVersion: Int, incomingVersion: Int)
}

public struct AdapterPackVerifier: Sendable {
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

    public func verify(_ pack: SignedAdapterPack, now: Date = Date()) throws -> AdapterPackPayload {
        guard pack.payload.schemaVersion == 1 else {
            throw AdapterPackError.unsupportedSchema(pack.payload.schemaVersion)
        }
        guard let key = trustedPublicKeys[pack.keyID] else {
            throw AdapterPackError.untrustedKey(pack.keyID)
        }
        guard let signatureData = Data(base64Encoded: pack.signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              key.isValidSignature(signature, for: AdapterCanonicalizer.canonicalData(pack.payload)) else {
            throw AdapterPackError.invalidSignature
        }
        if let expiresAt = pack.payload.expiresAt {
            guard expiresAt >= now, expiresAt.timeIntervalSince(pack.payload.issuedAt) <= maxValidity else {
                throw AdapterPackError.expired
            }
        }
        guard allowedPublishers.contains(pack.payload.publisher) else {
            throw AdapterPackError.publisherNotAllowed(pack.payload.publisher)
        }
        guard allowedCLIs.isEmpty || allowedCLIs.contains(pack.payload.cliName) else {
            throw AdapterPackError.cliNotAllowed(pack.payload.cliName)
        }
        try validateRules(pack.payload)
        return pack.payload
    }

    private func validateRules(_ payload: AdapterPackPayload) throws {
        var seen = Set<String>()
        for rule in payload.rules {
            guard !rule.resource.isEmpty, !rule.verb.isEmpty else {
                throw AdapterPackError.invalidRule("empty resource or verb")
            }
            let key = "\(rule.resource)\u{1f}\(rule.verb)"
            guard seen.insert(key).inserted else {
                throw AdapterPackError.invalidRule("duplicate rule \(rule.resource) \(rule.verb)")
            }
            if rule.risk == .readOnly {
                guard rule.actionClass?.contains("delete") != true, rule.actionClass?.contains("destroy") != true else {
                    throw AdapterPackError.invalidRule("read-only destructive-looking action class")
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

public struct DynamicCommandAdapter: CommandAdapter {
    public let payload: AdapterPackPayload
    public let adapterHash: String

    public var cliName: String { payload.cliName }
    public var adapterVersion: Int { payload.adapterVersion }

    public init(payload: AdapterPackPayload) {
        self.payload = payload
        self.adapterHash = AdapterCanonicalizer.hash(payload)
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
                warnings.append("Unknown flag \(token) makes classification high-risk.")
                leaseInvalidators.append("unknown-flag")
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
        let identity = AdapterIdentity(adapterID: payload.adapterID, adapterVersion: payload.adapterVersion, adapterHash: adapterHash, publisher: payload.publisher)

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

public struct AdapterRegistry: Sendable {
    public var adapters: [any CommandAdapter]
    private var installedVersions: [String: Int]

    public init(adapters: [any CommandAdapter] = []) {
        self.adapters = adapters
        self.installedVersions = Dictionary(uniqueKeysWithValues: adapters.map { ($0.cliName, $0.adapterVersion) })
    }

    public mutating func installVerified(payload: AdapterPackPayload) throws {
        if let current = installedVersions[payload.adapterID], payload.adapterVersion < current {
            throw AdapterPackError.rollback(adapterID: payload.adapterID, currentVersion: current, incomingVersion: payload.adapterVersion)
        }
        adapters.removeAll { $0.cliName == payload.cliName }
        adapters.append(DynamicCommandAdapter(payload: payload))
        installedVersions[payload.adapterID] = payload.adapterVersion
    }
}

public struct AdapterRegistryEntry: Codable, Equatable, Sendable {
    public var payload: AdapterPackPayload
    public var adapterHash: String
    public var installedAt: Date
    public var revokedAt: Date?

    public init(payload: AdapterPackPayload, adapterHash: String = "", installedAt: Date = Date(), revokedAt: Date? = nil) {
        self.payload = payload
        self.adapterHash = adapterHash.isEmpty ? AdapterCanonicalizer.hash(payload) : adapterHash
        self.installedAt = installedAt
        self.revokedAt = revokedAt
    }
}

public struct AdapterRegistryDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entries: [AdapterRegistryEntry]

    public init(schemaVersion: Int = 1, entries: [AdapterRegistryEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

public enum AdapterRegistryStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case missingAdapter(String)
}

public struct AdapterRegistryStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func loadDocument() throws -> AdapterRegistryDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AdapterRegistryDocument()
        }
        let document = try JSONDecoder().decode(AdapterRegistryDocument.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else {
            throw AdapterRegistryStoreError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    public func saveDocument(_ document: AdapterRegistryDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(document).write(to: url, options: [.atomic])
    }

    public func install(payload: AdapterPackPayload, now: Date = Date()) throws {
        var document = try loadDocument()
        document.entries.removeAll { $0.payload.adapterID == payload.adapterID }
        document.entries.append(AdapterRegistryEntry(payload: payload, installedAt: now))
        try saveDocument(document)
    }

    public func revoke(adapterID: String, now: Date = Date()) throws {
        var document = try loadDocument()
        guard let index = document.entries.firstIndex(where: { $0.payload.adapterID == adapterID }) else {
            throw AdapterRegistryStoreError.missingAdapter(adapterID)
        }
        document.entries[index].revokedAt = now
        try saveDocument(document)
    }

    public func activeRegistry() throws -> AdapterRegistry {
        var registry = AdapterRegistry()
        for entry in try loadDocument().entries where entry.revokedAt == nil {
            try registry.installVerified(payload: entry.payload)
        }
        return registry
    }
}

public struct AdapterGoldenFixture: Codable, Equatable, Sendable {
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

public enum AdapterGoldenFixtureError: Error, Equatable {
    case mismatch(expected: AdapterGoldenFixture, actualRisk: RiskLevel, actualActionClass: String)
}

public enum AdapterGoldenFixtureRunner {
    public static func run(fixtures: [AdapterGoldenFixture], registry: AdapterRegistry) throws {
        let classifier = CommandClassifier(registry: registry)
        for fixture in fixtures {
            let command = classifier.classify(executableName: fixture.executableName, arguments: fixture.arguments)
            guard command.risk == fixture.expectedRisk, command.actionClass == fixture.expectedActionClass else {
                throw AdapterGoldenFixtureError.mismatch(expected: fixture, actualRisk: command.risk, actualActionClass: command.actionClass)
            }
        }
    }
}

public enum BuiltInAdapterPacks {
    public static func registry() -> AdapterRegistry {
        var registry = AdapterRegistry()
        try! registry.installVerified(payload: hcloud)
        try! registry.installVerified(payload: githubCLI)
        try! registry.installVerified(payload: terraform)
        return registry
    }

    public static let hcloud = AdapterPackPayload(
        adapterID: "com.agenticfortress.adapters.hcloud",
        adapterVersion: 1,
        cliName: "hcloud",
        supportedCLIVersions: ["1.*"],
        publisher: "AgenticFortress Builtins",
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

    public static let githubCLI = AdapterPackPayload(
        adapterID: "com.agenticfortress.adapters.gh",
        adapterVersion: 1,
        cliName: "gh",
        supportedCLIVersions: ["2.*"],
        publisher: "AgenticFortress Builtins",
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

    public static let terraform = AdapterPackPayload(
        adapterID: "com.agenticfortress.adapters.terraform",
        adapterVersion: 0,
        cliName: "terraform",
        supportedCLIVersions: [],
        publisher: "AgenticFortress Builtins",
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
