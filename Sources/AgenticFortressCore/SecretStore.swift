import Foundation
import LocalAuthentication
import Security

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

    public func withData<T>(_ body: (Data) throws -> T) rethrows -> T {
        try body(bytes)
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

public enum KeychainAuthenticationRequirement: String, Codable, Equatable, Sendable {
    case notRequired
    case presenceRequired
    case biometryCurrent

    public var requiresUserPresence: Bool {
        self == .presenceRequired || self == .biometryCurrent
    }
}

public struct KeychainSecretDescriptor: Codable, Equatable, Sendable {
    public var alias: SecretAlias
    public var service: String
    public var account: String
    public var label: String
    public var authentication: KeychainAuthenticationRequirement

    public init(alias: SecretAlias, service: String, account: String, label: String, authentication: KeychainAuthenticationRequirement) {
        self.alias = alias
        self.service = service
        self.account = account
        self.label = label
        self.authentication = authentication
    }
}

public enum KeychainSecretStoreError: Error, Equatable {
    case accessControlCreationFailed
    case unexpectedItemShape
    case keychainStatus(OSStatus)
}

public enum KeychainSecretQueryFactory {
    public static func accessControlFlags(for authentication: KeychainAuthenticationRequirement) -> SecAccessControlCreateFlags {
        switch authentication {
        case .notRequired:
            []
        case .presenceRequired:
            [.userPresence]
        case .biometryCurrent:
            [.biometryCurrentSet]
        }
    }

    public static func makeAccessControl(authentication: KeychainAuthenticationRequirement) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessControlFlags(for: authentication),
            &error
        ) else {
            if let error {
                throw error.takeRetainedValue() as Error
            }
            throw KeychainSecretStoreError.accessControlCreationFailed
        }
        return access
    }

    public static func addQuery(descriptor: KeychainSecretDescriptor, material: SecretMaterial) throws -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: descriptor.service,
            kSecAttrAccount: descriptor.account,
            kSecAttrLabel: descriptor.label,
            kSecUseDataProtectionKeychain: true
        ]
        if descriptor.authentication == .notRequired {
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        } else {
            query[kSecAttrAccessControl] = try makeAccessControl(authentication: descriptor.authentication)
        }
        material.withData { data in
            query[kSecValueData] = data
        }
        return query
    }

    public static func readQuery(descriptor: KeychainSecretDescriptor, context: LAContext) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: descriptor.service,
            kSecAttrAccount: descriptor.account,
            kSecUseDataProtectionKeychain: true,
            kSecUseAuthenticationContext: context,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
    }

    public static func deleteQuery(descriptor: KeychainSecretDescriptor) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: descriptor.service,
            kSecAttrAccount: descriptor.account,
            kSecUseDataProtectionKeychain: true
        ]
    }
}

public struct KeychainSecretStore: LocalSecretStore {
    public var service: String
    public var descriptors: [SecretAlias: KeychainSecretDescriptor]

    public init(service: String = "com.agenticfortress.secrets", descriptors: [KeychainSecretDescriptor] = []) {
        self.service = service
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.alias, $0) })
    }

    public func store(alias: SecretAlias, material: SecretMaterial, label: String, authentication: KeychainAuthenticationRequirement) throws {
        let descriptor = KeychainSecretDescriptor(alias: alias, service: service, account: alias.rawValue, label: label, authentication: authentication)
        _ = SecItemDelete(KeychainSecretQueryFactory.deleteQuery(descriptor: descriptor) as CFDictionary)
        let status = SecItemAdd(try KeychainSecretQueryFactory.addQuery(descriptor: descriptor, material: material) as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.keychainStatus(status)
        }
    }

    public func binding(for alias: SecretAlias) throws -> SecretBinding {
        let descriptor = descriptors[alias] ?? KeychainSecretDescriptor(alias: alias, service: service, account: alias.rawValue, label: alias.rawValue, authentication: .presenceRequired)
        return SecretBinding(alias: alias, storeKind: "keychain", externalID: "\(descriptor.service):\(descriptor.account)", environment: "local")
    }

    public func resolve(alias: SecretAlias, approvedFor session: ApprovalSession) throws -> SecretMaterial {
        guard session.secretAlias == alias else {
            throw SecretStoreError.accessDenied("approval-session-secret-mismatch")
        }
        let descriptor = descriptors[alias] ?? KeychainSecretDescriptor(alias: alias, service: service, account: alias.rawValue, label: alias.rawValue, authentication: .presenceRequired)
        let context = LAContext()
        context.localizedReason = [
            "AgenticFortress approval \(session.manifestDigest)",
            "Action: \(session.actionClass)",
            "Secret: \(alias.rawValue)"
        ].joined(separator: "\n")
        context.localizedCancelTitle = "Deny"
        var item: CFTypeRef?
        let status = SecItemCopyMatching(KeychainSecretQueryFactory.readQuery(descriptor: descriptor, context: context) as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.keychainStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainSecretStoreError.unexpectedItemShape
        }
        return SecretMaterial(bytes: data)
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
