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

