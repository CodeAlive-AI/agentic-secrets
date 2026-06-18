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
    public var policyPackID: String
    public var policyPackVersion: Int
    public var policyPackHash: String
    public var publisher: String

    public init(policyPackID: String, policyPackVersion: Int, policyPackHash: String, publisher: String) {
        self.policyPackID = policyPackID
        self.policyPackVersion = policyPackVersion
        self.policyPackHash = policyPackHash
        self.publisher = publisher
    }

    public var leaseComponent: String {
        "\(policyPackID)@\(policyPackVersion):\(policyPackHash)"
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
    public var matchedDestructiveTerm: String?
    public var matchedForbiddenTerm: String?

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
        leaseInvalidators: [String] = [],
        matchedDestructiveTerm: String? = nil,
        matchedForbiddenTerm: String? = nil
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
        self.matchedDestructiveTerm = matchedDestructiveTerm
        self.matchedForbiddenTerm = matchedForbiddenTerm
    }

    public var isForbidden: Bool {
        matchedForbiddenTerm != nil
    }
}

public protocol CommandAdapter: Sendable {
    var cliName: String { get }
    var policyPackVersion: Int { get }
    func classify(arguments: [String], observedVersion: String?) -> NormalizedCommand
}

public struct CommandClassifier: Sendable {
    private let policyPacks: [String: any CommandAdapter]
    private let commandPolicy: CommandPolicyConfig
    private let genericRunners: Set<String> = ["sh", "bash", "zsh", "fish", "node", "npm", "pnpm", "yarn", "python", "python3", "make", "docker", "docker-compose", "ansible", "terraform"]

    public init(policyPacks: [any CommandAdapter] = BuiltInPolicyPacks.registry().policyPacks, commandPolicy: CommandPolicyConfig = .default) {
        self.policyPacks = Dictionary(uniqueKeysWithValues: policyPacks.map { ($0.cliName, $0) })
        self.commandPolicy = commandPolicy
    }

    public init(registry: PolicyPackRegistry, commandPolicy: CommandPolicyConfig = .default) {
        self.policyPacks = Dictionary(uniqueKeysWithValues: registry.policyPacks.map { ($0.cliName, $0) })
        self.commandPolicy = commandPolicy
    }

    public func classify(executableName: String, arguments: [String], observedVersion: String? = nil) -> NormalizedCommand {
        let cli = executableName.split(separator: "/").last.map(String.init) ?? executableName
        if genericRunners.contains(cli) {
            return applyCommandPolicy(NormalizedCommand(
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
            ))
        }
        guard let adapter = policyPacks[cli] else {
            return applyCommandPolicy(NormalizedCommand(
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
            ))
        }
        return applyCommandPolicy(adapter.classify(arguments: arguments, observedVersion: observedVersion))
    }

    private func applyCommandPolicy(_ command: NormalizedCommand) -> NormalizedCommand {
        let tokens = command.canonicalCommand.flatMap(Self.policyTokens(in:))
        var updated = command
        if let term = firstMatch(in: tokens, terms: commandPolicy.forbiddenTerms) {
            updated.risk = .unknown
            updated.confidence = .highRisk
            updated.matchedForbiddenTerm = term
            updated.warnings.append("Command matched forbidden term '\(term)' and will be denied by policy.")
        } else if let term = firstMatch(in: tokens, terms: commandPolicy.destructiveTerms) {
            updated.risk = .destructive
            updated.confidence = .highRisk
            updated.matchedDestructiveTerm = term
            updated.warnings.append("Command matched destructive term '\(term)' and requires fresh approval.")
        } else if updated.risk == .destructive {
            updated.risk = .mutating
            updated.warnings.append("Adapter marked this command destructive, but no local destructive term matched.")
        }
        updated.warnings = Array(NSOrderedSet(array: updated.warnings)) as? [String] ?? updated.warnings
        return updated
    }

    private func firstMatch(in tokens: [String], terms: [String]) -> String? {
        let normalizedTerms = CommandPolicyConfig.normalizedTerms(terms)
        return normalizedTerms.first { term in
            tokens.contains { $0.contains(term) }
        }
    }

    private static func policyTokens(in value: String) -> [String] {
        value
            .lowercased()
            .split { character in
                character == "/" || character == "\\" || character == "." || character == "_" || character == "-" || character == ":" || character == "="
            }
            .map(String.init)
    }
}
