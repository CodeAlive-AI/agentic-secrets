import CryptoKit
import Foundation
import Security

public struct CLIRegistryIntegrity: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var algorithm: String
    public var keyID: String
    public var signature: String
    public var signedAt: Date

    public init(schemaVersion: Int = 1, algorithm: String, keyID: String, signature: String, signedAt: Date) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyID = keyID
        self.signature = signature
        self.signedAt = signedAt
    }
}

public enum CLIRegistryIntegrityError: Error, Equatable, CustomStringConvertible {
    case missingSignature(String)
    case unsupportedSchema(Int)
    case unsupportedAlgorithm(String)
    case wrongKeyID(expected: String, actual: String)
    case malformedSignature
    case signatureMismatch
    case keychainUnavailable(operation: String, status: Int32)

    public var description: String {
        switch self {
        case .missingSignature(let path):
            "CLI registry integrity signature is missing at \(path). Re-register or explicitly trust the current registry before running registered CLIs."
        case .unsupportedSchema(let schema):
            "Unsupported CLI registry integrity schema version: \(schema)"
        case .unsupportedAlgorithm(let algorithm):
            "Unsupported CLI registry integrity algorithm: \(algorithm)"
        case .wrongKeyID(let expected, let actual):
            "CLI registry integrity key mismatch. Expected \(expected), got \(actual)."
        case .malformedSignature:
            "CLI registry integrity signature is malformed."
        case .signatureMismatch:
            "CLI registry integrity check failed. The registered CLI trust database was modified outside AgenticFortress."
        case .keychainUnavailable(let operation, let status):
            "Keychain unavailable during CLI registry integrity \(operation): OSStatus \(status)"
        }
    }
}

public protocol CLIRegistryIntegrityProtector: Sendable {
    var algorithm: String { get }
    var keyID: String { get }
    func sign(_ data: Data, signedAt: Date) throws -> CLIRegistryIntegrity
    func verify(_ data: Data, integrity: CLIRegistryIntegrity) throws
}

public struct HMACCLIRegistryIntegrityProtector: CLIRegistryIntegrityProtector {
    public let algorithm = "hmac-sha256-v1"
    public var keyID: String
    private var keyData: Data

    public init(keyID: String, keyData: Data) {
        self.keyID = keyID
        self.keyData = keyData
    }

    public func sign(_ data: Data, signedAt: Date = Date()) throws -> CLIRegistryIntegrity {
        let tag = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: keyData))
        return CLIRegistryIntegrity(
            algorithm: algorithm,
            keyID: keyID,
            signature: Data(tag).base64EncodedString(),
            signedAt: signedAt
        )
    }

    public func verify(_ data: Data, integrity: CLIRegistryIntegrity) throws {
        guard integrity.schemaVersion == 1 else {
            throw CLIRegistryIntegrityError.unsupportedSchema(integrity.schemaVersion)
        }
        guard integrity.algorithm == algorithm else {
            throw CLIRegistryIntegrityError.unsupportedAlgorithm(integrity.algorithm)
        }
        guard integrity.keyID == keyID else {
            throw CLIRegistryIntegrityError.wrongKeyID(expected: keyID, actual: integrity.keyID)
        }
        guard let signature = Data(base64Encoded: integrity.signature) else {
            throw CLIRegistryIntegrityError.malformedSignature
        }
        let valid = HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: data, using: SymmetricKey(data: keyData))
        guard valid else {
            throw CLIRegistryIntegrityError.signatureMismatch
        }
    }
}

public struct KeychainCLIRegistryIntegrityProtector: CLIRegistryIntegrityProtector {
    public let algorithm = "hmac-sha256-v1"
    public var service: String
    public var account: String

    public init(service: String = "com.agenticfortress.cli-registry-integrity", account: String) {
        self.service = service
        self.account = account
    }

    public var keyID: String {
        "keychain:hmac-sha256:" + shortDigest("\(service):\(account)", length: 20)
    }

    public func sign(_ data: Data, signedAt: Date = Date()) throws -> CLIRegistryIntegrity {
        try HMACCLIRegistryIntegrityProtector(keyID: keyID, keyData: loadOrCreateKey()).sign(data, signedAt: signedAt)
    }

    public func verify(_ data: Data, integrity: CLIRegistryIntegrity) throws {
        try HMACCLIRegistryIntegrityProtector(keyID: keyID, keyData: loadOrCreateKey()).verify(data, integrity: integrity)
    }

    private func loadOrCreateKey() throws -> Data {
        do {
            return try loadExistingKey()
        } catch CLIRegistryIntegrityError.keychainUnavailable(let operation, let status) where operation == "load" && status == errSecItemNotFound {
            return try createKey()
        }
    }

    private func loadExistingKey() throws -> Data {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw CLIRegistryIntegrityError.keychainUnavailable(operation: "load", status: status)
        }
        guard let data = result as? Data, data.count == 32 else {
            throw CLIRegistryIntegrityError.keychainUnavailable(operation: "load", status: errSecDecode)
        }
        return data
    }

    private func createKey() throws -> Data {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var attributes = keychainQuery()
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = key
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return try loadExistingKey()
        }
        guard status == errSecSuccess else {
            throw CLIRegistryIntegrityError.keychainUnavailable(operation: "create", status: status)
        }
        return key
    }

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
