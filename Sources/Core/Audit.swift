import Foundation

public enum AuditMode: String, Codable, Sendable {
    case normal
    case debug
}

public struct AuditEvent: Codable, Equatable, Sendable {
    public var event: String
    public var decision: String
    public var decisionDigest: String
    public var flow: DeliveryFlow
    public var subjectID: String
    public var secretID: String
    public var actionClass: String
    public var targetIdentity: String
    public var workspaceHash: String
    public var delivery: DeliveryMode
    public var policyEpoch: Int
    public var approval: String
    public var outcome: String
    public var time: Date
    public var metadata: [String: String]

    public init(
        event: String,
        decision: String,
        decisionDigest: String = "",
        flow: DeliveryFlow,
        subjectID: String,
        secretID: String,
        actionClass: String,
        targetIdentity: String = "",
        workspaceHash: String = "",
        delivery: DeliveryMode,
        policyEpoch: Int,
        approval: String,
        outcome: String = "",
        time: Date,
        metadata: [String: String] = [:]
    ) {
        self.event = event
        self.decision = decision
        self.decisionDigest = decisionDigest
        self.flow = flow
        self.subjectID = subjectID
        self.secretID = secretID
        self.actionClass = actionClass
        self.targetIdentity = targetIdentity
        self.workspaceHash = workspaceHash
        self.delivery = delivery
        self.policyEpoch = policyEpoch
        self.approval = approval
        self.outcome = outcome.isEmpty ? decision : outcome
        self.time = time
        self.metadata = metadata
    }

    public static func delivery(
        manifest: DecisionManifest,
        decision: String,
        subjectID: String,
        policyEpoch: Int,
        approval: ApprovalOption,
        outcome: String,
        time: Date,
        metadata: [String: String] = [:]
    ) -> AuditEvent {
        AuditEvent(
            event: "secret_delivery",
            decision: decision,
            decisionDigest: manifest.digest,
            flow: manifest.flow,
            subjectID: subjectID,
            secretID: manifest.secret.alias,
            actionClass: manifest.actionClass,
            targetIdentity: manifest.target.identity,
            workspaceHash: manifest.workspace.canonicalHash,
            delivery: manifest.secret.delivery,
            policyEpoch: policyEpoch,
            approval: approval.rawValue,
            outcome: outcome,
            time: time,
            metadata: metadata
        )
    }
}

public enum AuditError: Error, Equatable {
    case rawSecretDetected(String)
    case debugLeaseExpired
}

public struct DebugLease: Codable, Equatable, Sendable {
    public var profile: String
    public var flow: DeliveryFlow
    public var expiresAt: Date
    public var visibleBannerRequired: Bool

    public init(profile: String, flow: DeliveryFlow, expiresAt: Date, visibleBannerRequired: Bool = true) {
        self.profile = profile
        self.flow = flow
        self.expiresAt = expiresAt
        self.visibleBannerRequired = visibleBannerRequired
    }
}

public final class AuditLog: @unchecked Sendable {
    private var events: [AuditEvent] = []
    private let lock = NSLock()
    private let redactor = Redactor()

    public init() {}

    public func append(_ event: AuditEvent, knownSecrets: [String] = []) throws {
        let encoded = try AgenticFortressJSON.encodePretty(event)
        for secret in knownSecrets where !secret.isEmpty && encoded.contains(secret) {
            throw AuditError.rawSecretDetected(secret)
        }
        let redacted = redactor.redact(encoded)
        if redacted != encoded {
            throw AuditError.rawSecretDetected("pattern")
        }
        lock.withLock {
            events.append(event)
        }
    }

    public func snapshot() -> [AuditEvent] {
        lock.withLock { events }
    }

    public func exportRedactedJSON() throws -> String {
        let encoded = try AgenticFortressJSON.encodePretty(snapshot())
        return redactor.redact(encoded)
    }
}
