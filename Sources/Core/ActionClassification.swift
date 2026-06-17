import Foundation

public enum RiskLevel: String, Codable, Equatable, Comparable, Sendable {
    case readOnly = "read-only"
    case mutating
    case destructive
    case unknown

    private var rank: Int {
        switch self {
        case .readOnly: 0
        case .mutating: 1
        case .destructive: 2
        case .unknown: 3
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ClassificationConfidence: String, Codable, Equatable, Sendable {
    case adapterTested = "adapter-tested"
    case heuristic = "heuristic"
    case highRisk = "high-risk"
}

public struct AdapterIdentity: Codable, Equatable, Sendable {
    public var adapterID: String
    public var adapterVersion: Int
    public var adapterHash: String
    public var publisher: String

    public init(adapterID: String, adapterVersion: Int, adapterHash: String, publisher: String) {
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.adapterHash = adapterHash
        self.publisher = publisher
    }

    public var leaseComponent: String {
        "\(adapterID)@\(adapterVersion):\(adapterHash)"
    }
}

public struct NormalizedCommand: Codable, Equatable, Sendable {
    public var cli: String
    public var version: String?
    public var adapterIdentity: AdapterIdentity?
    public var resource: String
    public var verb: String
    public var arguments: [String]
    public var globalFlags: [String: String]
    public var actionClass: String
    public var risk: RiskLevel
    public var confidence: ClassificationConfidence
    public var warnings: [String]
    public var canonicalCommand: [String]
    public var leaseInvalidators: [String]

    public init(
        cli: String,
        version: String? = nil,
        adapterIdentity: AdapterIdentity? = nil,
        resource: String,
        verb: String,
        arguments: [String],
        globalFlags: [String: String],
        actionClass: String,
        risk: RiskLevel,
        confidence: ClassificationConfidence,
        warnings: [String],
        canonicalCommand: [String],
        leaseInvalidators: [String] = []
    ) {
        self.cli = cli
        self.version = version
        self.adapterIdentity = adapterIdentity
        self.resource = resource
        self.verb = verb
        self.arguments = arguments
        self.globalFlags = globalFlags
        self.actionClass = actionClass
        self.risk = risk
        self.confidence = confidence
        self.warnings = warnings
        self.canonicalCommand = canonicalCommand
        self.leaseInvalidators = leaseInvalidators
    }
}

public protocol CommandAdapter: Sendable {
    var cliName: String { get }
    var adapterVersion: Int { get }
    func classify(arguments: [String], observedVersion: String?) -> NormalizedCommand
}

public struct CommandClassifier: Sendable {
    private let adapters: [String: any CommandAdapter]
    private let genericRunners: Set<String> = ["sh", "bash", "zsh", "fish", "node", "npm", "pnpm", "yarn", "python", "python3", "make", "docker", "docker-compose", "ansible", "terraform"]

    public init(adapters: [any CommandAdapter] = BuiltInAdapterPacks.registry().adapters) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.cliName, $0) })
    }

    public init(registry: AdapterRegistry) {
        self.adapters = Dictionary(uniqueKeysWithValues: registry.adapters.map { ($0.cliName, $0) })
    }

    public func classify(executableName: String, arguments: [String], observedVersion: String? = nil) -> NormalizedCommand {
        let cli = executableName.split(separator: "/").last.map(String.init) ?? executableName
        if genericRunners.contains(cli) {
            return NormalizedCommand(
                cli: cli,
                version: observedVersion,
                resource: "generic-runner",
                verb: arguments.first ?? "unknown",
                arguments: arguments,
                globalFlags: [:],
                actionClass: "\(cli).generic-runner",
                risk: .unknown,
                confidence: .highRisk,
                warnings: ["Generic runners do not receive raw long-lived secrets by default; use a proxy, fd/stdin, or token-file profile."],
                canonicalCommand: [cli] + arguments,
                leaseInvalidators: ["generic-runner-execution-graph"]
            )
        }
        guard let adapter = adapters[cli] else {
            return NormalizedCommand(
                cli: cli,
                version: observedVersion,
                resource: "unknown",
                verb: "unknown",
                arguments: arguments,
                globalFlags: [:],
                actionClass: "\(cli).unknown",
                risk: .unknown,
                confidence: .highRisk,
                warnings: ["No versioned adapter is installed for \(cli); env delivery is denied by default."],
                canonicalCommand: [cli] + arguments
            )
        }
        return adapter.classify(arguments: arguments, observedVersion: observedVersion)
    }
}
