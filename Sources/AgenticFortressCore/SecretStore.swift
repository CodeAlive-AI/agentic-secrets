import Foundation

public struct SecretAlias: Codable, Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct SecretBinding: Codable, Equatable, Sendable {
    public var alias: SecretAlias
    public var storeKind: String
    public var externalID: String
    public var environment: String

    public init(alias: SecretAlias, storeKind: String, externalID: String, environment: String) {
        self.alias = alias
        self.storeKind = storeKind
        self.externalID = externalID
        self.environment = environment
    }
}

public struct SecretMaterial: Equatable, Sendable {
    private let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public init(utf8: String) {
        self.bytes = Data(utf8.utf8)
    }

    public func withUTF8String<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(String(decoding: bytes, as: UTF8.self))
    }

    public var redactedDescription: String {
        "secret:\(bytes.count)-bytes:\(shortDigest(bytes.base64EncodedString(), length: 8))"
    }
}

public enum SecretStoreError: Error, Equatable {
    case missingBinding(SecretAlias)
    case missingSecret(SecretAlias)
    case accessDenied(String)
    case unsupported(String)
}

public protocol LocalSecretStore: Sendable {
    func binding(for alias: SecretAlias) throws -> SecretBinding
    func resolve(alias: SecretAlias, approvedFor session: ApprovalSession) throws -> SecretMaterial
}

public final class InMemorySecretStore: LocalSecretStore, @unchecked Sendable {
    private var bindings: [SecretAlias: SecretBinding]
    private var secrets: [SecretAlias: SecretMaterial]
    private let lock = NSLock()

    public init(bindings: [SecretBinding] = [], secrets: [SecretAlias: SecretMaterial] = [:]) {
        self.bindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.alias, $0) })
        self.secrets = secrets
    }

    public func put(binding: SecretBinding, material: SecretMaterial) {
        lock.withLock {
            bindings[binding.alias] = binding
            secrets[binding.alias] = material
        }
    }

    public func binding(for alias: SecretAlias) throws -> SecretBinding {
        try lock.withLock {
            guard let binding = bindings[alias] else {
                throw SecretStoreError.missingBinding(alias)
            }
            return binding
        }
    }

    public func resolve(alias: SecretAlias, approvedFor session: ApprovalSession) throws -> SecretMaterial {
        try lock.withLock {
            guard session.secretAlias == alias else {
                throw SecretStoreError.accessDenied("approval-session-secret-mismatch")
            }
            guard bindings[alias] != nil else {
                throw SecretStoreError.missingBinding(alias)
            }
            guard let material = secrets[alias] else {
                throw SecretStoreError.missingSecret(alias)
            }
            return material
        }
    }
}

public struct KeychainSecretStore: LocalSecretStore {
    public init() {}

    public func binding(for alias: SecretAlias) throws -> SecretBinding {
        throw SecretStoreError.unsupported("Keychain binding lookup requires macOS Security framework integration and must not be simulated as plaintext config.")
    }

    public func resolve(alias: SecretAlias, approvedFor session: ApprovalSession) throws -> SecretMaterial {
        throw SecretStoreError.unsupported("Keychain secret resolution must occur behind LocalAuthentication/Keychain access-control in the macOS integration layer.")
    }
}

public struct ApprovalSession: Codable, Equatable, Sendable {
    public var id: String
    public var manifestDigest: String
    public var actionClass: String
    public var secretAlias: SecretAlias
    public var approvalOption: ApprovalOption
    public var policyEpoch: Int
    public var expiresAt: Date

    public init(id: String, manifestDigest: String, actionClass: String, secretAlias: SecretAlias, approvalOption: ApprovalOption, policyEpoch: Int, expiresAt: Date) {
        self.id = id
        self.manifestDigest = manifestDigest
        self.actionClass = actionClass
        self.secretAlias = secretAlias
        self.approvalOption = approvalOption
        self.policyEpoch = policyEpoch
        self.expiresAt = expiresAt
    }
}

public enum ApprovalSessionError: Error, Equatable {
    case unknown
    case expired
    case digestMismatch
    case actionClassMismatch
    case policyEpochMismatch
    case secretAliasMismatch
}

public final class ApprovalSessionStore: @unchecked Sendable {
    private var sessions: [String: ApprovalSession] = [:]
    private let lock = NSLock()

    public init() {}

    public func create(manifest: DecisionManifest, policyEpoch: Int, ttl: TimeInterval, now: Date = Date()) -> ApprovalSession {
        let session = ApprovalSession(
            id: "appr_" + shortDigest(UUID().uuidString, length: 16),
            manifestDigest: manifest.digest,
            actionClass: manifest.actionClass,
            secretAlias: SecretAlias(manifest.secret.alias),
            approvalOption: manifest.approvalOptions.first ?? .deny,
            policyEpoch: policyEpoch,
            expiresAt: now.addingTimeInterval(ttl)
        )
        lock.withLock {
            sessions[session.id] = session
        }
        return session
    }

    public func validate(sessionID: String, manifest: DecisionManifest, policyEpoch: Int, now: Date = Date()) throws -> ApprovalSession {
        try lock.withLock {
            guard let session = sessions[sessionID] else {
                throw ApprovalSessionError.unknown
            }
            guard session.expiresAt >= now else {
                sessions.removeValue(forKey: sessionID)
                throw ApprovalSessionError.expired
            }
            guard session.manifestDigest == manifest.digest else {
                throw ApprovalSessionError.digestMismatch
            }
            guard session.actionClass == manifest.actionClass else {
                throw ApprovalSessionError.actionClassMismatch
            }
            guard session.policyEpoch == policyEpoch else {
                throw ApprovalSessionError.policyEpochMismatch
            }
            guard session.secretAlias.rawValue == manifest.secret.alias else {
                throw ApprovalSessionError.secretAliasMismatch
            }
            return session
        }
    }
}

