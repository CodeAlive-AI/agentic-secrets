import Foundation

public struct RollbackAnchor: Codable, Equatable, Sendable {
    public var latestPolicyEpoch: Int
    public var latestPolicyHash: String
    public var latestAuditHead: String
    public var latestAppVersion: String

    public init(latestPolicyEpoch: Int, latestPolicyHash: String, latestAuditHead: String, latestAppVersion: String) {
        self.latestPolicyEpoch = latestPolicyEpoch
        self.latestPolicyHash = latestPolicyHash
        self.latestAuditHead = latestAuditHead
        self.latestAppVersion = latestAppVersion
    }
}

public enum RollbackStatus: Equatable, Sendable {
    case valid
    case locked(String)
}

public struct RecoveryBundle: Codable, Equatable, Sendable {
    public var encryptedPolicy: Data
    public var encryptedAliasMap: Data
    public var providerBindingsWithoutPlaintextTokens: [String]
    public var auditHead: String
    public var epoch: Int
    public var policyHash: String

    public init(encryptedPolicy: Data, encryptedAliasMap: Data, providerBindingsWithoutPlaintextTokens: [String], auditHead: String, epoch: Int, policyHash: String) {
        self.encryptedPolicy = encryptedPolicy
        self.encryptedAliasMap = encryptedAliasMap
        self.providerBindingsWithoutPlaintextTokens = providerBindingsWithoutPlaintextTokens
        self.auditHead = auditHead
        self.epoch = epoch
        self.policyHash = policyHash
    }
}

public struct RollbackProtector: Sendable {
    public init() {}

    public func validate(policy: PolicyState, anchor: RollbackAnchor?) -> RollbackStatus {
        guard let anchor else { return .valid }
        if policy.epoch < anchor.latestPolicyEpoch {
            return .locked("Policy epoch \(policy.epoch) is older than device anchor \(anchor.latestPolicyEpoch).")
        }
        if policy.epoch == anchor.latestPolicyEpoch, policy.hash != anchor.latestPolicyHash {
            return .locked("Policy hash does not match device anchor.")
        }
        return .valid
    }

    public func lockIfRolledBack(policy: PolicyState, anchor: RollbackAnchor?) -> PolicyState {
        var next = policy
        if case .locked = validate(policy: policy, anchor: anchor) {
            next.locked = true
            next.rememberedLeases = []
        }
        return next
    }
}
