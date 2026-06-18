import Foundation

public enum BitwardenRuntimeOperation: String, Codable, Sendable {
    case readSecret = "read_secret"
    case rotateToken = "rotate_token"
}

public struct BitwardenSecretBinding: Codable, Equatable, Sendable {
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

public struct BitwardenInvocation: Codable, Equatable, Sendable {
    public var provider: String
    public var operation: BitwardenRuntimeOperation
    public var binding: BitwardenSecretBinding
    public var sinkIdentity: String
    public var expiresAt: Date
    public var maxUses: Int
}

public enum BitwardenProviderError: Error, Equatable {
    case runtimeListDenied
    case runtimeFetchProjectDenied
    case expired
    case wrongSink
    case invalidOperation
    case leaseRequired
    case rotationOutOfOrder
}

public protocol BitwardenSecretClient: Sendable {
    func fetchApprovedSecret(binding: BitwardenSecretBinding) throws -> SecretMaterial
}

public final class InMemoryBitwardenSecretClient: BitwardenSecretClient, @unchecked Sendable {
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

    public func fetchApprovedSecret(binding: BitwardenSecretBinding) throws -> SecretMaterial {
        try lock.withLock {
            guard let material = secrets[binding.secretID] else {
                throw BitwardenProviderError.invalidOperation
            }
            return material
        }
    }
}

public struct BitwardenProviderPolicy: Sendable {
    public init() {}

    public func authorizeRuntimeRead(alias: String, bindings: [BitwardenSecretBinding], sinkIdentity: String, now: Date = Date()) throws -> BitwardenInvocation {
        guard let binding = bindings.first(where: { $0.alias == alias }) else {
            throw BitwardenProviderError.invalidOperation
        }
        return BitwardenInvocation(provider: "agentic-secrets-bitwarden-providerd", operation: .readSecret, binding: binding, sinkIdentity: sinkIdentity, expiresAt: now.addingTimeInterval(30), maxUses: 1)
    }

    public func denyListAllInRuntime() throws {
        throw BitwardenProviderError.runtimeListDenied
    }

    public func denyFetchProjectInRuntime() throws {
        throw BitwardenProviderError.runtimeFetchProjectDenied
    }

    public func validate(invocation: BitwardenInvocation, sinkIdentity: String, now: Date = Date()) throws {
        guard invocation.operation == .readSecret else { throw BitwardenProviderError.invalidOperation }
        guard invocation.expiresAt >= now else { throw BitwardenProviderError.expired }
        guard invocation.sinkIdentity == sinkIdentity else { throw BitwardenProviderError.wrongSink }
    }
}

public enum ProviderEnvironment: String, Codable, Equatable, Sendable {
    case dev
    case staging
    case prod
}

public struct BitwardenProviderLeasePolicy: Codable, Equatable, Sendable {
    public var environment: ProviderEnvironment
    public var maxLeaseSeconds: TimeInterval
    public var requiresPerFetchApproval: Bool

    public init(environment: ProviderEnvironment, maxLeaseSeconds: TimeInterval, requiresPerFetchApproval: Bool) {
        self.environment = environment
        self.maxLeaseSeconds = maxLeaseSeconds
        self.requiresPerFetchApproval = requiresPerFetchApproval
    }

    public static func policy(for environment: ProviderEnvironment) -> BitwardenProviderLeasePolicy {
        switch environment {
        case .dev:
            BitwardenProviderLeasePolicy(environment: .dev, maxLeaseSeconds: 300, requiresPerFetchApproval: false)
        case .staging:
            BitwardenProviderLeasePolicy(environment: .staging, maxLeaseSeconds: 60, requiresPerFetchApproval: false)
        case .prod:
            BitwardenProviderLeasePolicy(environment: .prod, maxLeaseSeconds: 0, requiresPerFetchApproval: true)
        }
    }
}

public struct BitwardenProviderRuntime: Sendable {
    private let policy: BitwardenProviderPolicy
    private let client: BitwardenSecretClient

    public init(policy: BitwardenProviderPolicy = BitwardenProviderPolicy(), client: BitwardenSecretClient) {
        self.policy = policy
        self.client = client
    }

    public func fetchOne(invocation: BitwardenInvocation, sinkIdentity: String, now: Date = Date()) throws -> SecretMaterial {
        try policy.validate(invocation: invocation, sinkIdentity: sinkIdentity, now: now)
        return try client.fetchApprovedSecret(binding: invocation.binding)
    }
}

public struct BitwardenRotationPlan: Codable, Equatable, Sendable {
    public var steps: [String]

    public static let standard = BitwardenRotationPlan(steps: [
        "create new Bitwarden token",
        "store new token through the broker-owned local secret store",
        "test exact approved secret access",
        "switch binding",
        "invalidate provider leases",
        "revoke old token",
        "write redacted audit event"
    ])
}

public enum BitwardenRotationStep: String, Codable, Equatable, Sendable {
    case createdNewToken
    case storedInLocalSecretStore
    case testedExactSecretAccess
    case switchedBinding
    case invalidatedProviderLeases
    case revokedOldToken
    case wroteAuditEvent
}

public struct BitwardenRotationState: Codable, Equatable, Sendable {
    public var binding: BitwardenSecretBinding
    public var completedSteps: [BitwardenRotationStep]

    public init(binding: BitwardenSecretBinding, completedSteps: [BitwardenRotationStep] = []) {
        self.binding = binding
        self.completedSteps = completedSteps
    }

    public var isComplete: Bool {
        completedSteps == BitwardenRotationWorkflow.requiredSteps
    }
}

public enum BitwardenRotationWorkflow {
    public static let requiredSteps: [BitwardenRotationStep] = [
        .createdNewToken,
        .storedInLocalSecretStore,
        .testedExactSecretAccess,
        .switchedBinding,
        .invalidatedProviderLeases,
        .revokedOldToken,
        .wroteAuditEvent
    ]

    public static func advance(_ state: BitwardenRotationState, completing step: BitwardenRotationStep) throws -> BitwardenRotationState {
        guard state.completedSteps.count < requiredSteps.count,
              requiredSteps[state.completedSteps.count] == step else {
            throw BitwardenProviderError.rotationOutOfOrder
        }
        var next = state
        next.completedSteps.append(step)
        return next
    }
}
