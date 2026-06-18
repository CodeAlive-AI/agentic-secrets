import Foundation

public struct DeliveryIntent: Codable, Equatable, Sendable {
    public var flow: DeliveryFlow
    public var secretAlias: String
    public var delivery: DeliveryMode
    public var environmentName: String?
    public var workspace: String
    public var parentApp: String
    public var commandClass: String?

    public init(flow: DeliveryFlow, secretAlias: String, delivery: DeliveryMode, environmentName: String? = nil, workspace: String, parentApp: String, commandClass: String? = nil) {
        self.flow = flow
        self.secretAlias = secretAlias
        self.delivery = delivery
        self.environmentName = environmentName
        self.workspace = workspace
        self.parentApp = parentApp
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

    public var decisionID: String
    public var flow: DeliveryFlow
    public var risk: RiskLevel
    public var actionClass: String
    public var canonicalCommand: [String]
    public var target: Target
    public var secret: Secret
    public var workspace: Workspace
    public var deltas: [String]
    public var warnings: [String]
    public var approvalOptions: [ApprovalOption]
    public var typedChallenge: String?
    public var digest: String
}

public enum ApprovalOption: String, Codable, Equatable, Sendable {
    case once
    case readOnlyInWorkspace1h = "read_only_in_workspace_1h"
    case providerLease5m = "provider_lease_5m"
    case deny
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
            case .readOnly:
                [.once, .readOnlyInWorkspace1h, .deny]
            case .mutating, .destructive, .unknown:
                [.once, .deny]
            }
        }

        let seed = [
            intent.flow.rawValue,
            command.actionClass,
            command.canonicalCommand.joined(separator: "\u{001f}"),
            target.resolvedPath,
            target.identity,
            intent.secretAlias,
            intent.workspace,
            intent.parentApp
        ].joined(separator: "\u{001e}")
        let digest = groupedDigest(seed)

        return DecisionManifest(
            decisionID: "dec_" + shortDigest(seed, length: 10),
            flow: intent.flow,
            risk: command.risk,
            actionClass: command.actionClass,
            canonicalCommand: command.canonicalCommand,
            target: .init(kind: target.kind, display: command.cli, resolvedPath: target.resolvedPath, trustLevel: target.trustLevel, identity: target.identity),
            secret: .init(alias: intent.secretAlias, delivery: intent.delivery, environmentName: intent.environmentName),
            workspace: .init(display: intent.workspace, canonicalHash: "hmac:" + shortDigest("workspace:\(intent.workspace)", length: 16)),
            deltas: deltas + command.leaseInvalidators,
            warnings: Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings,
            approvalOptions: options,
            typedChallenge: command.risk >= .destructive ? digest : nil,
            digest: digest
        )
    }

    private func groupedDigest(_ value: String) -> String {
        let digest = shortDigest(value, length: 8).uppercased()
        let split = digest.index(digest.startIndex, offsetBy: 4)
        return "\(digest[..<split])-\(digest[split...])"
    }
}
