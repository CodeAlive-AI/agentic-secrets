import Foundation
import CryptoKit
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

public enum LocalEncryptedSecretStoreError: Error, Equatable, CustomStringConvertible {
    case corruptStore
    case missingKey
    case userCanceled
    case authenticationFailed(String)
    case unsupportedKeyFormat

    public var description: String {
        switch self {
        case .corruptStore:
            "corruptStore"
        case .missingKey:
            "missingKey"
        case .userCanceled:
            "userCanceled"
        case .authenticationFailed(let reason):
            "authenticationFailed(\(reason))"
        case .unsupportedKeyFormat:
            "unsupportedKeyFormat"
        }
    }
}

public struct LocalEncryptedSecretRecord: Codable, Equatable, Sendable {
    public var binding: SecretBinding
    public var nonce: String
    public var ciphertext: String
    public var tag: String

    public init(binding: SecretBinding, nonce: String, ciphertext: String, tag: String) {
        self.binding = binding
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public struct LocalEncryptedSecretFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var records: [String: LocalEncryptedSecretRecord]

    public init(schemaVersion: Int = 1, records: [String: LocalEncryptedSecretRecord] = [:]) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}

public struct LocalAuthenticationPolicyGate: Sendable {
    public init() {}

    public func authorize(reason: String, context: LAContext = LAContext()) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LocalAuthenticationResultBox()
        context.localizedReason = reason
        context.localizedCancelTitle = "Deny"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            if !success {
                result.set(error ?? LocalEncryptedSecretStoreError.authenticationFailed("unknown"))
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let authorizationError = result.error {
            throw Self.map(error: authorizationError)
        }
    }

    public static func map(error: Error) -> LocalEncryptedSecretStoreError {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain, let code = LAError.Code(rawValue: nsError.code) else {
            return .authenticationFailed(nsError.localizedDescription)
        }
        switch code {
        case .userCancel, .systemCancel, .appCancel:
            return .userCanceled
        default:
            return .authenticationFailed(codeDescription(code))
        }
    }

    private static func codeDescription(_ code: LAError.Code) -> String {
        switch code {
        case .authenticationFailed:
            "authenticationFailed"
        case .userCancel:
            "userCancel"
        case .userFallback:
            "userFallback"
        case .systemCancel:
            "systemCancel"
        case .passcodeNotSet:
            "passcodeNotSet"
        case .biometryNotAvailable:
            "biometryNotAvailable"
        case .biometryNotEnrolled:
            "biometryNotEnrolled"
        case .biometryLockout:
            "biometryLockout"
        case .appCancel:
            "appCancel"
        case .invalidContext:
            "invalidContext"
        case .notInteractive:
            "notInteractive"
        default:
            String(describing: code)
        }
    }
}

private final class LocalAuthenticationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.withLock { storedError }
    }

    func set(_ error: Error) {
        lock.withLock {
            storedError = error
        }
    }
}

public struct LocalEncryptedSecretStore: LocalSecretStore {
    public var storeURL: URL
    public var keyURL: URL
    public var authenticationGate: LocalAuthenticationPolicyGate

    public init(storeURL: URL, keyURL: URL, authenticationGate: LocalAuthenticationPolicyGate = LocalAuthenticationPolicyGate()) {
        self.storeURL = storeURL
        self.keyURL = keyURL
        self.authenticationGate = authenticationGate
    }

    public func store(alias: SecretAlias, material: SecretMaterial, label: String, environment: String = "local") throws {
        try prepareParentDirectories()
        var storeFile = try loadStoreFile()
        let key = try loadOrCreateKey()
        let sealedBox = try material.withData { data in
            try AES.GCM.seal(data, using: key)
        }
        let binding = SecretBinding(alias: alias, storeKind: "local-encrypted-file", externalID: storeURL.path, environment: environment)
        storeFile.records[alias.rawValue] = LocalEncryptedSecretRecord(
            binding: binding,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
        try writeStoreFile(storeFile)
    }

    public func delete(alias: SecretAlias) throws {
        var storeFile = try loadStoreFile()
        storeFile.records.removeValue(forKey: alias.rawValue)
        try writeStoreFile(storeFile)
    }

    public func binding(for alias: SecretAlias) throws -> SecretBinding {
        let storeFile = try loadStoreFile()
        guard let record = storeFile.records[alias.rawValue] else {
            throw SecretStoreError.missingBinding(alias)
        }
        return record.binding
    }

    public func resolve(alias: SecretAlias, approvedFor session: ApprovalSession) throws -> SecretMaterial {
        guard session.secretAlias == alias else {
            throw SecretStoreError.accessDenied("approval-session-secret-mismatch")
        }
        let storeFile = try loadStoreFile()
        guard let record = storeFile.records[alias.rawValue] else {
            throw SecretStoreError.missingSecret(alias)
        }
        try authenticationGate.authorize(reason: session.authenticationReason)
        let key = try loadExistingKey()
        guard let nonceData = Data(base64Encoded: record.nonce),
              let ciphertext = Data(base64Encoded: record.ciphertext),
              let tag = Data(base64Encoded: record.tag) else {
            throw LocalEncryptedSecretStoreError.corruptStore
        }
        let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
        return SecretMaterial(bytes: try AES.GCM.open(sealedBox, using: key))
    }

    private func prepareParentDirectories() throws {
        try createPrivateDirectory(storeURL.deletingLastPathComponent())
        try createPrivateDirectory(keyURL.deletingLastPathComponent())
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func loadStoreFile() throws -> LocalEncryptedSecretFile {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return LocalEncryptedSecretFile()
        }
        let data = try Data(contentsOf: storeURL)
        let storeFile = try JSONDecoder().decode(LocalEncryptedSecretFile.self, from: data)
        guard storeFile.schemaVersion == 1 else {
            throw LocalEncryptedSecretStoreError.corruptStore
        }
        return storeFile
    }

    private func writeStoreFile(_ storeFile: LocalEncryptedSecretFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(storeFile).write(to: storeURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if FileManager.default.fileExists(atPath: keyURL.path) {
            return try loadExistingKey()
        }
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try bytes.write(to: keyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return SymmetricKey(data: bytes)
    }

    private func loadExistingKey() throws -> SymmetricKey {
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            throw LocalEncryptedSecretStoreError.missingKey
        }
        let data = try Data(contentsOf: keyURL)
        guard data.count == 32 else {
            throw LocalEncryptedSecretStoreError.unsupportedKeyFormat
        }
        return SymmetricKey(data: data)
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

public enum KeychainStorageBackend: String, Codable, Equatable, Sendable {
    case loginKeychain
    case dataProtectionKeychain

    public var requiresRestrictedSigningEntitlement: Bool {
        self == .dataProtectionKeychain
    }
}

public struct KeychainSecretDescriptor: Codable, Equatable, Sendable {
    public var alias: SecretAlias
    public var service: String
    public var account: String
    public var label: String
    public var authentication: KeychainAuthenticationRequirement
    public var backend: KeychainStorageBackend

    public init(
        alias: SecretAlias,
        service: String,
        account: String,
        label: String,
        authentication: KeychainAuthenticationRequirement,
        backend: KeychainStorageBackend = .loginKeychain
    ) {
        self.alias = alias
        self.service = service
        self.account = account
        self.label = label
        self.authentication = authentication
        self.backend = backend
    }
}

public enum KeychainSecretStoreError: Error, Equatable {
    case accessControlCreationFailed
    case unexpectedItemShape
    case userCanceled
    case keychainStatus(OSStatus)

    public static func from(status: OSStatus) -> KeychainSecretStoreError {
        if status == errSecUserCanceled {
            return .userCanceled
        }
        return .keychainStatus(status)
    }
}

public enum KeychainSecretQueryFactory {
    private static func applyBackend(_ backend: KeychainStorageBackend, to query: inout [CFString: Any]) {
        if backend == .dataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
    }

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
            kSecAttrLabel: descriptor.label
        ]
        applyBackend(descriptor.backend, to: &query)
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
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: descriptor.service,
            kSecAttrAccount: descriptor.account,
            kSecUseAuthenticationContext: context,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        applyBackend(descriptor.backend, to: &query)
        return query
    }

    public static func deleteQuery(descriptor: KeychainSecretDescriptor) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: descriptor.service,
            kSecAttrAccount: descriptor.account
        ]
        applyBackend(descriptor.backend, to: &query)
        return query
    }
}

public struct KeychainSecretStore: LocalSecretStore {
    public var service: String
    public var descriptors: [SecretAlias: KeychainSecretDescriptor]
    public var backend: KeychainStorageBackend

    public init(service: String = "com.agenticfortress.secrets", backend: KeychainStorageBackend = .loginKeychain, descriptors: [KeychainSecretDescriptor] = []) {
        self.service = service
        self.backend = backend
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.alias, $0) })
    }

    public func store(alias: SecretAlias, material: SecretMaterial, label: String, authentication: KeychainAuthenticationRequirement) throws {
        let descriptor = KeychainSecretDescriptor(alias: alias, service: service, account: alias.rawValue, label: label, authentication: authentication, backend: backend)
        _ = SecItemDelete(KeychainSecretQueryFactory.deleteQuery(descriptor: descriptor) as CFDictionary)
        let status = SecItemAdd(try KeychainSecretQueryFactory.addQuery(descriptor: descriptor, material: material) as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.from(status: status)
        }
    }

    public func delete(alias: SecretAlias) throws {
        let descriptor = descriptors[alias] ?? KeychainSecretDescriptor(alias: alias, service: service, account: alias.rawValue, label: alias.rawValue, authentication: .presenceRequired, backend: backend)
        let status = SecItemDelete(KeychainSecretQueryFactory.deleteQuery(descriptor: descriptor) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.from(status: status)
        }
    }

    public func binding(for alias: SecretAlias) throws -> SecretBinding {
        let descriptor = descriptors[alias] ?? KeychainSecretDescriptor(alias: alias, service: service, account: alias.rawValue, label: alias.rawValue, authentication: .presenceRequired, backend: backend)
        return SecretBinding(alias: alias, storeKind: "keychain", externalID: "\(descriptor.service):\(descriptor.account)", environment: "local")
    }

    public func resolve(alias: SecretAlias, approvedFor session: ApprovalSession) throws -> SecretMaterial {
        guard session.secretAlias == alias else {
            throw SecretStoreError.accessDenied("approval-session-secret-mismatch")
        }
        let descriptor = descriptors[alias] ?? KeychainSecretDescriptor(alias: alias, service: service, account: alias.rawValue, label: alias.rawValue, authentication: .presenceRequired, backend: backend)
        let context = LAContext()
        context.localizedReason = session.authenticationReason
        context.localizedCancelTitle = "Deny"
        var item: CFTypeRef?
        let status = SecItemCopyMatching(KeychainSecretQueryFactory.readQuery(descriptor: descriptor, context: context) as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.from(status: status)
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
    public var authenticationReason: String

    public init(
        id: String,
        manifestDigest: String,
        actionClass: String,
        secretAlias: SecretAlias,
        approvalOption: ApprovalOption,
        policyEpoch: Int,
        expiresAt: Date,
        authenticationReason: String
    ) {
        self.id = id
        self.manifestDigest = manifestDigest
        self.actionClass = actionClass
        self.secretAlias = secretAlias
        self.approvalOption = approvalOption
        self.policyEpoch = policyEpoch
        self.expiresAt = expiresAt
        self.authenticationReason = authenticationReason
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
            expiresAt: now.addingTimeInterval(ttl),
            authenticationReason: LocalAuthenticationGate.reason(for: manifest)
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
