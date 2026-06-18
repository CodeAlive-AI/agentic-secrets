import Foundation

public enum ProvenanceConfidence: String, Codable, Equatable, Comparable, Sendable {
    case none
    case environmentHint = "environment-hint"
    case processTree = "process-tree"
    case socketPeer = "socket-peer"
    case xpcPeer = "xpc-peer"
    case endpointSecurity = "endpoint-security"

    private var rank: Int {
        switch self {
        case .none: 0
        case .environmentHint: 1
        case .processTree: 2
        case .socketPeer: 3
        case .xpcPeer: 4
        case .endpointSecurity: 5
        }
    }

    public static func < (lhs: ProvenanceConfidence, rhs: ProvenanceConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct DeliveryIntent: Codable, Equatable, Sendable {
    public var flow: DeliveryFlow
    public var secretAlias: String
    public var delivery: DeliveryMode
    public var environmentName: String?
    public var workspace: String
    public var originHint: String
    public var provenanceConfidence: ProvenanceConfidence
    public var commandClass: String?

    public init(
        flow: DeliveryFlow,
        secretAlias: String,
        delivery: DeliveryMode,
        environmentName: String? = nil,
        workspace: String,
        originHint: String,
        provenanceConfidence: ProvenanceConfidence = .environmentHint,
        commandClass: String? = nil
    ) {
        self.flow = flow
        self.secretAlias = secretAlias
        self.delivery = delivery
        self.environmentName = environmentName
        self.workspace = workspace
        self.originHint = originHint
        self.provenanceConfidence = provenanceConfidence
        self.commandClass = commandClass
    }
}

public struct DecisionManifest: Codable, Equatable, Sendable {
    public struct Target: Codable, Equatable, Sendable {
        public var kind: String
        public var display: String
        public var resolvedPath: String
        public var trustLevel: String
        public var identity: String
    }

    public struct Secret: Codable, Equatable, Sendable {
        public var alias: String
        public var delivery: DeliveryMode
        public var environmentName: String?
    }

    public struct Workspace: Codable, Equatable, Sendable {
        public var display: String
        public var canonicalHash: String
    }

    public struct Origin: Codable, Equatable, Sendable {
        public var hint: String
        public var provenanceConfidence: ProvenanceConfidence
    }

    public var decisionID: String
    public var flow: DeliveryFlow
    public var risk: RiskLevel
    public var actionClass: String
    public var canonicalCommand: [String]
    public var commandDigest: String
    public var configContext: String
    public var adapterIdentity: String?
    public var target: Target
    public var secret: Secret
    public var workspace: Workspace
    public var origin: Origin
    public var deltas: [String]
    public var warnings: [String]
    public var approvalOptions: [ApprovalOption]
    public var typedChallenge: String?
    public var digest: String
}

public enum ApprovalOption: String, Codable, Equatable, Sendable {
    case once
    case short
    case remember24h = "remember-24h"
    case always
    case providerLease5m = "provider_lease_5m"
    case deny

    public init(authorizationMode: CLIAuthorizationMode) {
        switch authorizationMode {
        case .once:
            self = .once
        case .short:
            self = .short
        case .remember24h:
            self = .remember24h
        case .always:
            self = .always
        }
    }
}

public struct DecisionManifestFactory: Sendable {
    public init() {}

    public func make(command: NormalizedCommand, intent: DeliveryIntent, target: TargetAssessment, deltas: [String] = []) -> DecisionManifest {
        var warnings = command.warnings
        if intent.delivery == .env {
            warnings.append("Environment variables may be inherited by child processes.")
        }
        if command.isForbidden {
            warnings.insert("This command is blocked by local command policy.", at: 0)
        } else if command.risk >= .destructive {
            warnings.insert("High-risk approvals require fresh local authentication and typed challenge.", at: 0)
        }

        let options: [ApprovalOption] = if command.isForbidden {
            [.deny]
        } else {
            switch command.risk {
            case .destructive:
                [.once, .deny]
            case .readOnly, .mutating, .unknown:
                [.always, .remember24h, .short, .once, .deny]
            }
        }

        let configContext = Self.configContext(for: command, extraDeltas: deltas)
        let commandDigest = "sha256:" + stableDigest(command.canonicalCommand.joined(separator: "\u{001f}"))
        let adapterIdentity = command.adapterIdentity?.leaseComponent
        let seed = [
            intent.flow.rawValue,
            command.actionClass,
            commandDigest,
            configContext,
            adapterIdentity ?? "missing-adapter-identity",
            target.resolvedPath,
            target.identity,
            intent.secretAlias,
            intent.workspace,
            intent.originHint,
            intent.provenanceConfidence.rawValue
        ].joined(separator: "\u{001e}")
        let digest = groupedDigest(seed)

        return DecisionManifest(
            decisionID: "dec_" + shortDigest(seed, length: 10),
            flow: intent.flow,
            risk: command.risk,
            actionClass: command.actionClass,
            canonicalCommand: command.canonicalCommand,
            commandDigest: commandDigest,
            configContext: configContext,
            adapterIdentity: adapterIdentity,
            target: .init(kind: target.kind, display: command.cli, resolvedPath: target.resolvedPath, trustLevel: target.trustLevel, identity: target.identity),
            secret: .init(alias: intent.secretAlias, delivery: intent.delivery, environmentName: intent.environmentName),
            workspace: .init(display: intent.workspace, canonicalHash: "hmac:" + shortDigest("workspace:\(intent.workspace)", length: 16)),
            origin: .init(hint: intent.originHint, provenanceConfidence: intent.provenanceConfidence),
            deltas: deltas + command.leaseInvalidators,
            warnings: Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings,
            approvalOptions: options,
            typedChallenge: command.risk >= .destructive ? digest : nil,
            digest: digest
        )
    }

    public static func configContext(for command: NormalizedCommand, extraDeltas: [String] = []) -> String {
        let flags = command.globalFlags
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let invalidators = (extraDeltas + command.leaseInvalidators).sorted().map { "invalidator=\($0)" }
        let adapter = "adapter=\(command.adapterIdentity?.leaseComponent ?? "missing-adapter-identity")"
        return ([adapter] + flags + invalidators).joined(separator: ";")
    }

    private func groupedDigest(_ value: String) -> String {
        let digest = shortDigest(value, length: 8).uppercased()
        let split = digest.index(digest.startIndex, offsetBy: 4)
        return "\(digest[..<split])-\(digest[split...])"
    }
}
