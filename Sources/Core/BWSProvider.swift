import Foundation

public enum BWSRuntimeOperation: String, Codable, Sendable {
    case readSecret = "read_secret"
    case rotateToken = "rotate_token"
}

public struct BWSSecretBinding: Codable, Equatable, Sendable {
    public var alias: String
    public var projectID: String
    public var secretID: String
    public var environment: String

    public init(alias: String, projectID: String, secretID: String, environment: String) {
        self.alias = alias
        self.projectID = projectID
        self.secretID = secretID
        self.environment = environment
    }
}

public struct BWSInvocation: Codable, Equatable, Sendable {
    public var provider: String
    public var operation: BWSRuntimeOperation
    public var binding: BWSSecretBinding
    public var sinkIdentity: String
    public var expiresAt: Date
    public var maxUses: Int
}

public enum BWSProviderError: Error, Equatable {
    case runtimeListDenied
    case runtimeFetchProjectDenied
    case expired
    case wrongSink
    case invalidOperation
    case leaseRequired
    case rotationOutOfOrder
}

public protocol BWSSecretClient: Sendable {
    func readSecret(binding: BWSSecretBinding) throws -> SecretMaterial
}

public final class InMemoryBWSSecretClient: BWSSecretClient, @unchecked Sendable {
    private var secrets: [String: SecretMaterial]
    private let lock = NSLock()

    public init(secrets: [String: SecretMaterial] = [:]) {
        self.secrets = secrets
    }

    public func put(secretID: String, material: SecretMaterial) {
        lock.withLock {
            secrets[secretID] = material
        }
    }

    public func readSecret(binding: BWSSecretBinding) throws -> SecretMaterial {
        try lock.withLock {
            guard let material = secrets[binding.secretID] else {
                throw BWSProviderError.invalidOperation
            }
            return material
        }
    }
}

public struct BWSProviderPolicy: Sendable {
    public init() {}

    public func authorizeRuntimeRead(alias: String, bindings: [BWSSecretBinding], sinkIdentity: String, now: Date = Date()) throws -> BWSInvocation {
        guard let binding = bindings.first(where: { $0.alias == alias }) else {
            throw BWSProviderError.invalidOperation
        }
        return BWSInvocation(provider: "agentic-fortress-bwsd", operation: .readSecret, binding: binding, sinkIdentity: sinkIdentity, expiresAt: now.addingTimeInterval(30), maxUses: 1)
    }

    public func denyListAllInRuntime() throws {
        throw BWSProviderError.runtimeListDenied
    }

    public func denyFetchProjectInRuntime() throws {
        throw BWSProviderError.runtimeFetchProjectDenied
    }

    public func validate(invocation: BWSInvocation, sinkIdentity: String, now: Date = Date()) throws {
        guard invocation.operation == .readSecret else { throw BWSProviderError.invalidOperation }
        guard invocation.expiresAt >= now else { throw BWSProviderError.expired }
        guard invocation.sinkIdentity == sinkIdentity else { throw BWSProviderError.wrongSink }
    }
}

public enum ProviderEnvironment: String, Codable, Equatable, Sendable {
    case dev
    case staging
    case prod
}

public struct BWSProviderLeasePolicy: Codable, Equatable, Sendable {
    public var environment: ProviderEnvironment
    public var maxLeaseSeconds: TimeInterval
    public var requiresPerFetchApproval: Bool

    public init(environment: ProviderEnvironment, maxLeaseSeconds: TimeInterval, requiresPerFetchApproval: Bool) {
        self.environment = environment
        self.maxLeaseSeconds = maxLeaseSeconds
        self.requiresPerFetchApproval = requiresPerFetchApproval
    }

    public static func policy(for environment: ProviderEnvironment) -> BWSProviderLeasePolicy {
        switch environment {
        case .dev:
            BWSProviderLeasePolicy(environment: .dev, maxLeaseSeconds: 300, requiresPerFetchApproval: false)
        case .staging:
            BWSProviderLeasePolicy(environment: .staging, maxLeaseSeconds: 60, requiresPerFetchApproval: false)
        case .prod:
            BWSProviderLeasePolicy(environment: .prod, maxLeaseSeconds: 0, requiresPerFetchApproval: true)
        }
    }
}

public struct BWSProviderRuntime: Sendable {
    private let policy: BWSProviderPolicy
    private let client: BWSSecretClient

    public init(policy: BWSProviderPolicy = BWSProviderPolicy(), client: BWSSecretClient) {
        self.policy = policy
        self.client = client
    }

    public func fetchOne(invocation: BWSInvocation, sinkIdentity: String, now: Date = Date()) throws -> SecretMaterial {
        try policy.validate(invocation: invocation, sinkIdentity: sinkIdentity, now: now)
        return try client.readSecret(binding: invocation.binding)
    }
}

public struct BWSRotationPlan: Codable, Equatable, Sendable {
    public var steps: [String]

    public static let standard = BWSRotationPlan(steps: [
        "create new BWS token",
        "store new token in Keychain under agentic-fortress-bwsd ownership",
        "test exact approved secret access",
        "switch binding",
        "invalidate provider leases",
        "revoke old token",
        "write redacted audit event"
    ])
}

public enum BWSRotationStep: String, Codable, Equatable, Sendable {
    case createdNewToken
    case storedInKeychain
    case testedExactSecretAccess
    case switchedBinding
    case invalidatedProviderLeases
    case revokedOldToken
    case wroteAuditEvent
}

public struct BWSRotationState: Codable, Equatable, Sendable {
    public var binding: BWSSecretBinding
    public var completedSteps: [BWSRotationStep]

    public init(binding: BWSSecretBinding, completedSteps: [BWSRotationStep] = []) {
        self.binding = binding
        self.completedSteps = completedSteps
    }

    public var isComplete: Bool {
        completedSteps == BWSRotationWorkflow.requiredSteps
    }
}

public enum BWSRotationWorkflow {
    public static let requiredSteps: [BWSRotationStep] = [
        .createdNewToken,
        .storedInKeychain,
        .testedExactSecretAccess,
        .switchedBinding,
        .invalidatedProviderLeases,
        .revokedOldToken,
        .wroteAuditEvent
    ]

    public static func advance(_ state: BWSRotationState, completing step: BWSRotationStep) throws -> BWSRotationState {
        guard state.completedSteps.count < requiredSteps.count,
              requiredSteps[state.completedSteps.count] == step else {
            throw BWSProviderError.rotationOutOfOrder
        }
        var next = state
        next.completedSteps.append(step)
        return next
    }
}
