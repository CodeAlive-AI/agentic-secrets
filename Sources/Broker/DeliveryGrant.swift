import CryptoKit
import Foundation

public struct DeliveryGrantScope: Codable, Equatable, Sendable {
    public var subject: String
    public var secretAlias: String
    public var environmentName: String?
    public var workspaceHash: String
    public var originHint: String
    public var provenanceConfidence: ProvenanceConfidence
    public var actionClass: String
    public var commandDigest: String
    public var risk: RiskLevel
    public var configContext: String
    public var deliveryMode: DeliveryMechanism
    public var targetIdentity: String
    public var targetResolvedPath: String

    public init(
        subject: String,
        secretAlias: String,
        environmentName: String?,
        workspaceHash: String,
        originHint: String,
        provenanceConfidence: ProvenanceConfidence,
        actionClass: String,
        commandDigest: String,
        risk: RiskLevel,
        configContext: String,
        deliveryMode: DeliveryMechanism,
        targetIdentity: String,
        targetResolvedPath: String
    ) {
        self.subject = subject
        self.secretAlias = secretAlias
        self.environmentName = environmentName
        self.workspaceHash = workspaceHash
        self.originHint = originHint
        self.provenanceConfidence = provenanceConfidence
        self.actionClass = actionClass
        self.commandDigest = commandDigest
        self.risk = risk
        self.configContext = configContext
        self.deliveryMode = deliveryMode
        self.targetIdentity = targetIdentity
        self.targetResolvedPath = targetResolvedPath
    }

    public init(manifest: DeliveryDecisionManifest) {
        self.init(
            subject: manifest.target.display,
            secretAlias: manifest.secret.alias,
            environmentName: manifest.secret.environmentName,
            workspaceHash: manifest.workspace.canonicalHash,
            originHint: manifest.origin.hint,
            provenanceConfidence: manifest.origin.provenanceConfidence,
            actionClass: manifest.actionClass,
            commandDigest: manifest.commandDigest,
            risk: manifest.risk,
            configContext: manifest.configContext,
            deliveryMode: manifest.secret.delivery,
            targetIdentity: manifest.target.identity,
            targetResolvedPath: manifest.target.resolvedPath
        )
    }

    public func withOriginHint(_ originHint: String) -> DeliveryGrantScope {
        var copy = self
        copy.originHint = originHint
        return copy
    }
}

public struct DeliveryGrant: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var scopeDigest: String
    public var scope: DeliveryGrantScope?
    public var grantedAt: Date
    public var expiresAt: Date
    public var signature: String

    public init(schemaVersion: Int = 1, scopeDigest: String, scope: DeliveryGrantScope? = nil, grantedAt: Date, expiresAt: Date, signature: String) {
        self.schemaVersion = schemaVersion
        self.scopeDigest = scopeDigest
        self.scope = scope
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }
}

public struct DeliveryGrantDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var grants: [String: DeliveryGrant]

    public init(schemaVersion: Int = 1, grants: [String: DeliveryGrant] = [:]) {
        self.schemaVersion = schemaVersion
        self.grants = grants
    }
}

public enum DeliveryGrantError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case malformedSignature
    case signatureMismatch
    case invalidTTL
    case missingKey
    case unsupportedKeyFormat

    public var description: String {
        switch self {
        case .unsupportedSchema(let schema):
            "Unsupported CLI delivery grant schema version: \(schema)"
        case .malformedSignature:
            "CLI delivery grant signature is malformed."
        case .signatureMismatch:
            "CLI delivery grant signature mismatch."
        case .invalidTTL:
            "CLI delivery grant TTL must be greater than 0 and no more than \(Int(DeliveryGrantPolicy.maxTTL)) seconds."
        case .missingKey:
            "CLI delivery grant key is missing."
        case .unsupportedKeyFormat:
            "CLI delivery grant key must be 256 bits."
        }
    }
}

public enum DeliveryGrantPolicy {
    public static let defaultTTL: TimeInterval = 300
    public static let maxTTL: TimeInterval = 900

    public static func allowsReuse(scope: DeliveryGrantScope) -> Bool {
        scope.risk != .destructive
    }
}

public enum DeliveryAuthorizationMode: String, Codable, Equatable, Sendable {
    case once
    case short
    case remember24h = "remember-24h"
    case always

    public var isPersistent: Bool {
        self == .remember24h || self == .always
    }
}

public enum RememberedApprovalPolicy {
    public static let defaultMode: DeliveryAuthorizationMode = .always
    public static let remember24HTTL: TimeInterval = 86_400

    public static func allowsPersistentGrant(manifest: DeliveryDecisionManifest) -> Bool {
        manifest.risk != .destructive
    }
}

public struct RememberedApprovalScope: Codable, Equatable, Sendable {
    public var subject: String
    public var secretAlias: String
    public var environmentName: String?
    public var workspaceHash: String
    public var originHint: String
    public var provenanceConfidence: ProvenanceConfidence
    public var configContext: String
    public var adapterIdentity: String?
    public var deliveryMode: DeliveryMechanism
    public var targetIdentity: String
    public var targetResolvedPath: String

    public init(
        subject: String,
        secretAlias: String,
        environmentName: String?,
        workspaceHash: String,
        originHint: String,
        provenanceConfidence: ProvenanceConfidence,
        configContext: String,
        adapterIdentity: String?,
        deliveryMode: DeliveryMechanism,
        targetIdentity: String,
        targetResolvedPath: String
    ) {
        self.subject = subject
        self.secretAlias = secretAlias
        self.environmentName = environmentName
        self.workspaceHash = workspaceHash
        self.originHint = originHint
        self.provenanceConfidence = provenanceConfidence
        self.configContext = configContext
        self.adapterIdentity = adapterIdentity
        self.deliveryMode = deliveryMode
        self.targetIdentity = targetIdentity
        self.targetResolvedPath = targetResolvedPath
    }

    public init(manifest: DeliveryDecisionManifest) {
        self.init(
            subject: manifest.target.display,
            secretAlias: manifest.secret.alias,
            environmentName: manifest.secret.environmentName,
            workspaceHash: manifest.workspace.canonicalHash,
            originHint: manifest.origin.hint,
            provenanceConfidence: manifest.origin.provenanceConfidence,
            configContext: manifest.configContext,
            adapterIdentity: manifest.adapterIdentity,
            deliveryMode: manifest.secret.delivery,
            targetIdentity: manifest.target.identity,
            targetResolvedPath: manifest.target.resolvedPath
        )
    }
}

public struct RememberedApproval: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var scopeDigest: String
    public var scope: RememberedApprovalScope
    public var mode: DeliveryAuthorizationMode
    public var grantedAt: Date
    public var expiresAt: Date?
    public var lastUsedAt: Date?
    public var signature: String

    public init(
        schemaVersion: Int = 1,
        scopeDigest: String,
        scope: RememberedApprovalScope,
        mode: DeliveryAuthorizationMode,
        grantedAt: Date,
        expiresAt: Date?,
        lastUsedAt: Date? = nil,
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.scopeDigest = scopeDigest
        self.scope = scope
        self.mode = mode
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.signature = signature
    }
}

public struct RememberedApprovalDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var grants: [String: RememberedApproval]

    public init(schemaVersion: Int = 1, grants: [String: RememberedApproval] = [:]) {
        self.schemaVersion = schemaVersion
        self.grants = grants
    }
}

public enum RememberedApprovalError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case invalidMode(DeliveryAuthorizationMode)
    case malformedSignature
    case signatureMismatch
    case scopeMismatch
    case missingKey
    case unsupportedKeyFormat

    public var description: String {
        switch self {
        case .unsupportedSchema(let schema):
            "Unsupported CLI persistent allow grant schema version: \(schema)"
        case .invalidMode(let mode):
            "CLI persistent allow grant mode is not persistent: \(mode.rawValue)"
        case .malformedSignature:
            "CLI persistent allow grant signature is malformed."
        case .signatureMismatch:
            "CLI persistent allow grant signature mismatch."
        case .scopeMismatch:
            "CLI persistent allow grant scope mismatch."
        case .missingKey:
            "CLI persistent allow grant key is missing."
        case .unsupportedKeyFormat:
            "CLI persistent allow grant key must be 256 bits."
        }
    }
}

public struct DeliveryGrantStore: Sendable {
    public var url: URL
    public var keyURL: URL
    public var maxTTL: TimeInterval

    public init(url: URL, keyURL: URL, maxTTL: TimeInterval = DeliveryGrantPolicy.maxTTL) {
        self.url = url
        self.keyURL = keyURL
        self.maxTTL = maxTTL
    }

    public func validGrant(scope: DeliveryGrantScope, now: Date = Date()) throws -> DeliveryGrant? {
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
    public func grant(scope: DeliveryGrantScope, ttl: TimeInterval, now: Date = Date()) throws -> DeliveryGrant {
        guard ttl > 0, ttl <= maxTTL else {
            throw DeliveryGrantError.invalidTTL
        }
        var document = try load()
        let digest = try scopeDigest(scope)
        let grant = DeliveryGrant(
            scopeDigest: digest,
            scope: scope,
            grantedAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            signature: try signature(scopeDigest: digest, grantedAt: now, expiresAt: now.addingTimeInterval(ttl))
        )
        document.grants = document.grants.filter { $0.value.expiresAt >= now }
        document.grants[digest] = grant
        try save(document, now: now)
        return grant
    }

    public func scopeDigest(_ scope: DeliveryGrantScope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(scope)
        return "sha256:" + stableDigest(String(decoding: data, as: UTF8.self))
    }

    private func load() throws -> DeliveryGrantDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DeliveryGrantDocument()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(DeliveryGrantDocument.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else {
            throw DeliveryGrantError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    private func save(_ document: DeliveryGrantDocument, now: Date) throws {
        var cleaned = document
        cleaned.grants = cleaned.grants.filter { $0.value.expiresAt >= now }
        try createPrivateDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(cleaned).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func verify(grant: DeliveryGrant, scopeDigest: String) throws {
        guard grant.schemaVersion == 1 else {
            throw DeliveryGrantError.unsupportedSchema(grant.schemaVersion)
        }
        guard let expected = Data(base64Encoded: grant.signature) else {
            throw DeliveryGrantError.malformedSignature
        }
        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            expected,
            authenticating: signatureData(scopeDigest: scopeDigest, grantedAt: grant.grantedAt, expiresAt: grant.expiresAt),
            using: SymmetricKey(data: try loadOrCreateKey())
        )
        guard valid else {
            throw DeliveryGrantError.signatureMismatch
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
            "agentic-secrets-cli-unlock-v1",
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
                throw DeliveryGrantError.unsupportedKeyFormat
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

public struct RememberedApprovalStore: Sendable {
    public var url: URL
    public var keyURL: URL?
    private var integrityProtector: (any ToolRegistryIntegrityProtector)?

    public init(url: URL, keyURL: URL) {
        self.url = url
        self.keyURL = keyURL
        self.integrityProtector = nil
    }

    public init(url: URL, integrityProtector: any ToolRegistryIntegrityProtector) {
        self.url = url
        self.keyURL = nil
        self.integrityProtector = integrityProtector
    }

    public func validGrant(scope: RememberedApprovalScope, now: Date = Date()) throws -> RememberedApproval? {
        var document = try load()
        let digest = try scopeDigest(scope)
        guard var grant = document.grants[digest] else {
            return nil
        }
        guard grant.expiresAt.map({ $0 >= now }) ?? true else {
            document.grants.removeValue(forKey: digest)
            try save(document, now: now)
            return nil
        }
        try verify(grant: grant, expectedScope: scope, scopeDigest: digest)
        grant.lastUsedAt = now
        document.grants[digest] = grant
        try save(document, now: now)
        return grant
    }

    @discardableResult
    public func grant(scope: RememberedApprovalScope, mode: DeliveryAuthorizationMode, now: Date = Date()) throws -> RememberedApproval {
        guard mode == .remember24h || mode == .always else {
            throw RememberedApprovalError.invalidMode(mode)
        }
        var document = try load()
        let digest = try scopeDigest(scope)
        let expiresAt = mode == .remember24h ? now.addingTimeInterval(RememberedApprovalPolicy.remember24HTTL) : nil
        let grant = RememberedApproval(
            scopeDigest: digest,
            scope: scope,
            mode: mode,
            grantedAt: now,
            expiresAt: expiresAt,
            signature: try signature(scopeDigest: digest, mode: mode, grantedAt: now, expiresAt: expiresAt)
        )
        document.grants = document.grants.filter { _, grant in
            grant.expiresAt.map { $0 >= now } ?? true
        }
        document.grants[digest] = grant
        try save(document, now: now)
        return grant
    }

    public func scopeDigest(_ scope: RememberedApprovalScope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(scope)
        return "sha256:" + stableDigest(String(decoding: data, as: UTF8.self))
    }

    private func load() throws -> RememberedApprovalDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RememberedApprovalDocument()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(RememberedApprovalDocument.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else {
            throw RememberedApprovalError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    private func save(_ document: RememberedApprovalDocument, now: Date) throws {
        var cleaned = document
        cleaned.grants = cleaned.grants.filter { _, grant in
            grant.expiresAt.map { $0 >= now } ?? true
        }
        try createPrivateDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(cleaned).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func verify(grant: RememberedApproval, expectedScope: RememberedApprovalScope, scopeDigest: String) throws {
        guard grant.schemaVersion == 1 else {
            throw RememberedApprovalError.unsupportedSchema(grant.schemaVersion)
        }
        guard grant.scope == expectedScope else {
            throw RememberedApprovalError.scopeMismatch
        }
        guard try self.scopeDigest(grant.scope) == scopeDigest else {
            throw RememberedApprovalError.scopeMismatch
        }
        guard let expected = Data(base64Encoded: grant.signature) else {
            throw RememberedApprovalError.malformedSignature
        }
        let data = signatureData(scopeDigest: scopeDigest, mode: grant.mode, grantedAt: grant.grantedAt, expiresAt: grant.expiresAt)
        if let integrityProtector {
            let integrity = ToolRegistryIntegrity(
                algorithm: integrityProtector.algorithm,
                keyID: integrityProtector.keyID,
                signature: grant.signature,
                signedAt: grant.grantedAt
            )
            do {
                try integrityProtector.verify(data, integrity: integrity)
            } catch ToolRegistryIntegrityError.malformedSignature {
                throw RememberedApprovalError.malformedSignature
            } catch ToolRegistryIntegrityError.signatureMismatch {
                throw RememberedApprovalError.signatureMismatch
            }
            return
        }
        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            expected,
            authenticating: data,
            using: SymmetricKey(data: try loadOrCreateKey())
        )
        guard valid else {
            throw RememberedApprovalError.signatureMismatch
        }
    }

    private func signature(scopeDigest: String, mode: DeliveryAuthorizationMode, grantedAt: Date, expiresAt: Date?) throws -> String {
        if let integrityProtector {
            return try integrityProtector.sign(
                signatureData(scopeDigest: scopeDigest, mode: mode, grantedAt: grantedAt, expiresAt: expiresAt),
                signedAt: grantedAt
            ).signature
        }
        let tag = HMAC<SHA256>.authenticationCode(
            for: signatureData(scopeDigest: scopeDigest, mode: mode, grantedAt: grantedAt, expiresAt: expiresAt),
            using: SymmetricKey(data: try loadOrCreateKey())
        )
        return Data(tag).base64EncodedString()
    }

    private func signatureData(scopeDigest: String, mode: DeliveryAuthorizationMode, grantedAt: Date, expiresAt: Date?) -> Data {
        let payload = [
            "agentic-secrets-cli-persistent-allow-v1",
            scopeDigest,
            mode.rawValue,
            String(Int(grantedAt.timeIntervalSince1970)),
            expiresAt.map { String(Int($0.timeIntervalSince1970)) } ?? "never"
        ].joined(separator: "\u{1F}")
        return Data(payload.utf8)
    }

    private func loadOrCreateKey() throws -> Data {
        guard let keyURL else {
            throw RememberedApprovalError.missingKey
        }
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let key = try Data(contentsOf: keyURL)
            guard key.count == 32 else {
                throw RememberedApprovalError.unsupportedKeyFormat
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
