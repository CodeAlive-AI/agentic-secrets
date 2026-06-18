import Foundation

public struct LeaseScope: Codable, Equatable, Sendable {
    public var subject: String
    public var adapterIdentity: String
    public var secretAlias: String
    public var workspaceHash: String
    public var originHint: String
    public var actionClass: String
    public var configContext: String
    public var deliveryMode: DeliveryMode
    public var targetIdentity: String

    public init(subject: String, adapterIdentity: String = "builtin-legacy", secretAlias: String, workspaceHash: String, originHint: String, actionClass: String, configContext: String, deliveryMode: DeliveryMode, targetIdentity: String) {
        self.subject = subject
        self.adapterIdentity = adapterIdentity
        self.secretAlias = secretAlias
        self.workspaceHash = workspaceHash
        self.originHint = originHint
        self.actionClass = actionClass
        self.configContext = configContext
        self.deliveryMode = deliveryMode
        self.targetIdentity = targetIdentity
    }
}

public struct CryptoLease: Codable, Equatable, Sendable {
    public var id: String
    public var scope: LeaseScope
    public var risk: RiskLevel
    public var expiresAt: Date
    public var policyEpoch: Int

    public init(id: String, scope: LeaseScope, risk: RiskLevel, expiresAt: Date, policyEpoch: Int) {
        self.id = id
        self.scope = scope
        self.risk = risk
        self.expiresAt = expiresAt
        self.policyEpoch = policyEpoch
    }
}

public enum PolicyDecision: Codable, Equatable, Sendable {
    case allowOnce
    case allowRemembered(CryptoLease)
    case deny(String)
}

public struct PolicyState: Codable, Equatable, Sendable {
    public var epoch: Int
    public var hash: String
    public var locked: Bool
    public var rememberedLeases: [CryptoLease]

    public init(epoch: Int = 1, hash: String = "initial", locked: Bool = false, rememberedLeases: [CryptoLease] = []) {
        self.epoch = epoch
        self.hash = hash
        self.locked = locked
        self.rememberedLeases = rememberedLeases
    }
}

public enum PolicyError: Error, Equatable {
    case locked
    case genericEnvDenied
    case destructiveRememberDenied
    case forbiddenCommand(String)
    case unknownDenied
}

public struct PolicyEngine: Sendable {
    public init() {}

    public func authorize(command: NormalizedCommand, intent: DeliveryIntent, target: TargetAssessment, approval: ApprovalOption, state: PolicyState, now: Date = Date()) throws -> PolicyDecision {
        guard !state.locked else { throw PolicyError.locked }
        if let term = command.matchedForbiddenTerm {
            throw PolicyError.forbiddenCommand(term)
        }
        if command.confidence == .highRisk, intent.delivery == .env, command.cli != "hcloud", command.cli != "gh" {
            throw PolicyError.genericEnvDenied
        }
        switch approval {
        case .deny:
            return .deny("user-denied")
        case .once:
            return .allowOnce
        case .readOnlyInWorkspace1h:
            guard command.risk == .readOnly else { throw PolicyError.destructiveRememberDenied }
            let scope = LeaseScope(subject: command.cli, adapterIdentity: command.adapterIdentity?.leaseComponent ?? "missing-adapter-identity", secretAlias: intent.secretAlias, workspaceHash: "hmac:" + shortDigest(intent.workspace, length: 16), originHint: intent.originHint, actionClass: command.actionClass, configContext: DecisionManifestFactory.configContext(for: command), deliveryMode: intent.delivery, targetIdentity: target.identity)
            return .allowRemembered(CryptoLease(id: "lease_" + shortDigest(UUID().uuidString, length: 16), scope: scope, risk: command.risk, expiresAt: now.addingTimeInterval(3600), policyEpoch: state.epoch))
        case .providerLease5m:
            let scope = LeaseScope(subject: command.cli, adapterIdentity: command.adapterIdentity?.leaseComponent ?? "missing-adapter-identity", secretAlias: intent.secretAlias, workspaceHash: "hmac:" + shortDigest(intent.workspace, length: 16), originHint: intent.originHint, actionClass: command.actionClass, configContext: "provider;\(DecisionManifestFactory.configContext(for: command))", deliveryMode: intent.delivery, targetIdentity: target.identity)
            return .allowRemembered(CryptoLease(id: "lease_" + shortDigest(UUID().uuidString, length: 16), scope: scope, risk: command.risk, expiresAt: now.addingTimeInterval(300), policyEpoch: state.epoch))
        }
    }
}
