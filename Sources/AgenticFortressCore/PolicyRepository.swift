import CryptoKit
import Foundation

public struct PolicyDatabaseEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var policy: PolicyState
    public var macHex: String

    public init(schemaVersion: Int = 1, policy: PolicyState, macHex: String) {
        self.schemaVersion = schemaVersion
        self.policy = policy
        self.macHex = macHex
    }
}

public enum PolicyRepositoryError: Error, Equatable {
    case macMismatch
    case plaintextSecretDetected
    case unsupportedSchema(Int)
}

public protocol PolicyRepository: Sendable {
    func load() throws -> PolicyState
    func save(_ policy: PolicyState) throws
}

public struct FilePolicyRepository: PolicyRepository {
    public var url: URL
    private let macKey: SymmetricKey
    private let redactor = Redactor()

    public init(url: URL, macKeyData: Data) {
        self.url = url
        self.macKey = SymmetricKey(data: macKeyData)
    }

    public func load() throws -> PolicyState {
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(PolicyDatabaseEnvelope.self, from: data)
        guard envelope.schemaVersion == 1 else {
            throw PolicyRepositoryError.unsupportedSchema(envelope.schemaVersion)
        }
        let policyData = try canonicalPolicyData(envelope.policy)
        guard Self.macHex(policyData, key: macKey) == envelope.macHex else {
            throw PolicyRepositoryError.macMismatch
        }
        return envelope.policy
    }

    public func save(_ policy: PolicyState) throws {
        let policyData = try canonicalPolicyData(policy)
        let encodedPolicy = String(decoding: policyData, as: UTF8.self)
        guard redactor.redact(encodedPolicy) == encodedPolicy else {
            throw PolicyRepositoryError.plaintextSecretDetected
        }
        let envelope = PolicyDatabaseEnvelope(policy: policy, macHex: Self.macHex(policyData, key: macKey))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func canonicalPolicyData(_ policy: PolicyState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(policy)
    }

    private static func macHex(_ data: Data, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public protocol RollbackAnchorRepository: Sendable {
    func loadAnchor() throws -> RollbackAnchor?
    func saveAnchor(_ anchor: RollbackAnchor) throws
}

public final class InMemoryRollbackAnchorRepository: RollbackAnchorRepository, @unchecked Sendable {
    private var anchor: RollbackAnchor?
    private let lock = NSLock()

    public init(anchor: RollbackAnchor? = nil) {
        self.anchor = anchor
    }

    public func loadAnchor() throws -> RollbackAnchor? {
        lock.withLock { anchor }
    }

    public func saveAnchor(_ anchor: RollbackAnchor) throws {
        lock.withLock {
            self.anchor = anchor
        }
    }
}

public enum RecoveryBundleError: Error, Equatable {
    case plaintextProviderTokenDetected
}

public enum RecoveryBundleFactory {
    public static func export(policy: PolicyState, aliasMap: [String: String], providerBindingsWithoutPlaintextTokens: [String], auditHead: String) throws -> RecoveryBundle {
        let encodedPolicy = try JSONEncoder().encode(policy)
        let encodedAliasMap = try JSONEncoder().encode(aliasMap)
        for binding in providerBindingsWithoutPlaintextTokens {
            let redacted = Redactor().redact(binding)
            if redacted != binding {
                throw RecoveryBundleError.plaintextProviderTokenDetected
            }
        }
        return RecoveryBundle(
            encryptedPolicy: Data(encodedPolicy.base64EncodedString().utf8),
            encryptedAliasMap: Data(encodedAliasMap.base64EncodedString().utf8),
            providerBindingsWithoutPlaintextTokens: providerBindingsWithoutPlaintextTokens,
            auditHead: auditHead,
            epoch: policy.epoch,
            policyHash: policy.hash
        )
    }
}

