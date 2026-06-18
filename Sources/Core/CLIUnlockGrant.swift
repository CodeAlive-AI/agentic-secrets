import CryptoKit
import Foundation

public struct CLIUnlockScope: Codable, Equatable, Sendable {
    public var subject: String
    public var secretAlias: String
    public var environmentName: String?
    public var workspaceHash: String
    public var parentApp: String
    public var deliveryMode: DeliveryMode
    public var targetIdentity: String
    public var targetResolvedPath: String

    public init(
        subject: String,
        secretAlias: String,
        environmentName: String?,
        workspaceHash: String,
        parentApp: String,
        deliveryMode: DeliveryMode,
        targetIdentity: String,
        targetResolvedPath: String
    ) {
        self.subject = subject
        self.secretAlias = secretAlias
        self.environmentName = environmentName
        self.workspaceHash = workspaceHash
        self.parentApp = parentApp
        self.deliveryMode = deliveryMode
        self.targetIdentity = targetIdentity
        self.targetResolvedPath = targetResolvedPath
    }

    public init(manifest: DecisionManifest) {
        self.init(
            subject: manifest.target.display,
            secretAlias: manifest.secret.alias,
            environmentName: manifest.secret.environmentName,
            workspaceHash: manifest.workspace.canonicalHash,
            parentApp: "",
            deliveryMode: manifest.secret.delivery,
            targetIdentity: manifest.target.identity,
            targetResolvedPath: manifest.target.resolvedPath
        )
    }

    public func withParentApp(_ parentApp: String) -> CLIUnlockScope {
        var copy = self
        copy.parentApp = parentApp
        return copy
    }
}

public struct CLIUnlockGrant: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var scopeDigest: String
    public var grantedAt: Date
    public var expiresAt: Date
    public var signature: String

    public init(schemaVersion: Int = 1, scopeDigest: String, grantedAt: Date, expiresAt: Date, signature: String) {
        self.schemaVersion = schemaVersion
        self.scopeDigest = scopeDigest
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }
}

public struct CLIUnlockGrantDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var grants: [String: CLIUnlockGrant]

    public init(schemaVersion: Int = 1, grants: [String: CLIUnlockGrant] = [:]) {
        self.schemaVersion = schemaVersion
        self.grants = grants
    }
}

public enum CLIUnlockGrantError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case malformedSignature
    case signatureMismatch
    case invalidTTL
    case missingKey
    case unsupportedKeyFormat

    public var description: String {
        switch self {
        case .unsupportedSchema(let schema):
            "Unsupported CLI unlock grant schema version: \(schema)"
        case .malformedSignature:
            "CLI unlock grant signature is malformed."
        case .signatureMismatch:
            "CLI unlock grant signature mismatch."
        case .invalidTTL:
            "CLI unlock grant TTL must be greater than 0 and no more than \(Int(CLIUnlockGrantPolicy.maxTTL)) seconds."
        case .missingKey:
            "CLI unlock grant key is missing."
        case .unsupportedKeyFormat:
            "CLI unlock grant key must be 256 bits."
        }
    }
}

public enum CLIUnlockGrantPolicy {
    public static let defaultTTL: TimeInterval = 300
    public static let maxTTL: TimeInterval = 900
}

public struct CLIUnlockGrantStore: Sendable {
    public var url: URL
    public var keyURL: URL
    public var maxTTL: TimeInterval

    public init(url: URL, keyURL: URL, maxTTL: TimeInterval = CLIUnlockGrantPolicy.maxTTL) {
        self.url = url
        self.keyURL = keyURL
        self.maxTTL = maxTTL
    }

    public func validGrant(scope: CLIUnlockScope, now: Date = Date()) throws -> CLIUnlockGrant? {
        var document = try load()
        let digest = try scopeDigest(scope)
        guard let grant = document.grants[digest] else {
            return nil
        }
        guard grant.expiresAt >= now else {
            document.grants.removeValue(forKey: digest)
            try save(document, now: now)
            return nil
        }
        try verify(grant: grant, scopeDigest: digest)
        return grant
    }

    @discardableResult
    public func grant(scope: CLIUnlockScope, ttl: TimeInterval, now: Date = Date()) throws -> CLIUnlockGrant {
        guard ttl > 0, ttl <= maxTTL else {
            throw CLIUnlockGrantError.invalidTTL
        }
        var document = try load()
        let digest = try scopeDigest(scope)
        let grant = CLIUnlockGrant(
            scopeDigest: digest,
            grantedAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            signature: try signature(scopeDigest: digest, grantedAt: now, expiresAt: now.addingTimeInterval(ttl))
        )
        document.grants = document.grants.filter { $0.value.expiresAt >= now }
        document.grants[digest] = grant
        try save(document, now: now)
        return grant
    }

    public func scopeDigest(_ scope: CLIUnlockScope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(scope)
        return "sha256:" + stableDigest(String(decoding: data, as: UTF8.self))
    }

    private func load() throws -> CLIUnlockGrantDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CLIUnlockGrantDocument()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CLIUnlockGrantDocument.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else {
            throw CLIUnlockGrantError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    private func save(_ document: CLIUnlockGrantDocument, now: Date) throws {
        var cleaned = document
        cleaned.grants = cleaned.grants.filter { $0.value.expiresAt >= now }
        try createPrivateDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(cleaned).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func verify(grant: CLIUnlockGrant, scopeDigest: String) throws {
        guard grant.schemaVersion == 1 else {
            throw CLIUnlockGrantError.unsupportedSchema(grant.schemaVersion)
        }
        guard let expected = Data(base64Encoded: grant.signature) else {
            throw CLIUnlockGrantError.malformedSignature
        }
        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            expected,
            authenticating: signatureData(scopeDigest: scopeDigest, grantedAt: grant.grantedAt, expiresAt: grant.expiresAt),
            using: SymmetricKey(data: try loadOrCreateKey())
        )
        guard valid else {
            throw CLIUnlockGrantError.signatureMismatch
        }
    }

    private func signature(scopeDigest: String, grantedAt: Date, expiresAt: Date) throws -> String {
        let tag = HMAC<SHA256>.authenticationCode(
            for: signatureData(scopeDigest: scopeDigest, grantedAt: grantedAt, expiresAt: expiresAt),
            using: SymmetricKey(data: try loadOrCreateKey())
        )
        return Data(tag).base64EncodedString()
    }

    private func signatureData(scopeDigest: String, grantedAt: Date, expiresAt: Date) -> Data {
        let payload = [
            "agentic-fortress-cli-unlock-v1",
            scopeDigest,
            String(Int(grantedAt.timeIntervalSince1970)),
            String(Int(expiresAt.timeIntervalSince1970))
        ].joined(separator: "\u{1F}")
        return Data(payload.utf8)
    }

    private func loadOrCreateKey() throws -> Data {
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let key = try Data(contentsOf: keyURL)
            guard key.count == 32 else {
                throw CLIUnlockGrantError.unsupportedKeyFormat
            }
            return key
        }
        try createPrivateDirectory(keyURL.deletingLastPathComponent())
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try key.write(to: keyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
