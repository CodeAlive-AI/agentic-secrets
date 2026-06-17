import CryptoKit
import Darwin
import Foundation

public struct CodeSigningRequirement: Codable, Equatable, Sendable {
    public var teamID: String
    public var bundleID: String
    public var minimumVersion: String
    public var hardenedRuntimeRequired: Bool

    public init(teamID: String, bundleID: String, minimumVersion: String, hardenedRuntimeRequired: Bool = true) {
        self.teamID = teamID
        self.bundleID = bundleID
        self.minimumVersion = minimumVersion
        self.hardenedRuntimeRequired = hardenedRuntimeRequired
    }
}

public struct XPCPeerIdentity: Codable, Equatable, Sendable {
    public var teamID: String
    public var bundleID: String
    public var version: String
    public var hardenedRuntime: Bool
    public var debugSigned: Bool

    public init(teamID: String, bundleID: String, version: String, hardenedRuntime: Bool, debugSigned: Bool = false) {
        self.teamID = teamID
        self.bundleID = bundleID
        self.version = version
        self.hardenedRuntime = hardenedRuntime
        self.debugSigned = debugSigned
    }
}

public enum XPCPeerValidationError: Error, Equatable {
    case wrongTeamID
    case wrongBundleID
    case oldVersion
    case hardenedRuntimeMissing
    case debugSignedRejected
}

public enum XPCPeerValidator {
    public static func validate(peer: XPCPeerIdentity, requirement: CodeSigningRequirement, allowDebugSigned: Bool = false) throws {
        guard peer.teamID == requirement.teamID else { throw XPCPeerValidationError.wrongTeamID }
        guard peer.bundleID == requirement.bundleID else { throw XPCPeerValidationError.wrongBundleID }
        guard compareVersion(peer.version, requirement.minimumVersion) >= 0 else { throw XPCPeerValidationError.oldVersion }
        if requirement.hardenedRuntimeRequired {
            guard peer.hardenedRuntime else { throw XPCPeerValidationError.hardenedRuntimeMissing }
        }
        if !allowDebugSigned {
            guard !peer.debugSigned else { throw XPCPeerValidationError.debugSignedRejected }
        }
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

public struct SelfBuildPeerIdentity: Codable, Equatable, Sendable {
    public var helperName: String
    public var resolvedPath: String
    public var ownerUserID: UInt32
    public var fileMode: UInt16
    public var parentMode: UInt16
    public var version: String
    public var binarySHA256: String
    public var cdHash: String?
    public var debugSigned: Bool

    public init(
        helperName: String,
        resolvedPath: String,
        ownerUserID: UInt32,
        fileMode: UInt16,
        parentMode: UInt16,
        version: String,
        binarySHA256: String,
        cdHash: String? = nil,
        debugSigned: Bool = false
    ) {
        self.helperName = helperName
        self.resolvedPath = resolvedPath
        self.ownerUserID = ownerUserID
        self.fileMode = fileMode
        self.parentMode = parentMode
        self.version = version
        self.binarySHA256 = binarySHA256
        self.cdHash = cdHash
        self.debugSigned = debugSigned
    }
}

public struct SelfBuildPeerRequirement: Codable, Equatable, Sendable {
    public var helperName: String
    public var resolvedPath: String
    public var ownerUserID: UInt32
    public var minimumVersion: String
    public var binarySHA256: String
    public var cdHash: String?
    public var allowDebugSigned: Bool

    public init(
        helperName: String,
        resolvedPath: String,
        ownerUserID: UInt32,
        minimumVersion: String,
        binarySHA256: String,
        cdHash: String? = nil,
        allowDebugSigned: Bool = false
    ) {
        self.helperName = helperName
        self.resolvedPath = resolvedPath
        self.ownerUserID = ownerUserID
        self.minimumVersion = minimumVersion
        self.binarySHA256 = binarySHA256
        self.cdHash = cdHash
        self.allowDebugSigned = allowDebugSigned
    }
}

public enum SelfBuildPeerValidationError: Error, Equatable {
    case wrongHelperName
    case wrongPath
    case wrongOwner
    case worldWritableFile
    case worldWritableParent
    case groupWritableParent
    case oldVersion
    case wrongHash
    case wrongCDHash
    case debugSignedRejected
}

public enum SelfBuildPeerValidator {
    public static func validate(peer: SelfBuildPeerIdentity, requirement: SelfBuildPeerRequirement) throws {
        guard peer.helperName == requirement.helperName else { throw SelfBuildPeerValidationError.wrongHelperName }
        guard peer.resolvedPath == requirement.resolvedPath else { throw SelfBuildPeerValidationError.wrongPath }
        guard peer.ownerUserID == requirement.ownerUserID else { throw SelfBuildPeerValidationError.wrongOwner }
        guard peer.fileMode & 0o002 == 0 else { throw SelfBuildPeerValidationError.worldWritableFile }
        guard peer.parentMode & 0o002 == 0 else { throw SelfBuildPeerValidationError.worldWritableParent }
        guard peer.parentMode & 0o020 == 0 else { throw SelfBuildPeerValidationError.groupWritableParent }
        guard compareVersion(peer.version, requirement.minimumVersion) >= 0 else { throw SelfBuildPeerValidationError.oldVersion }
        guard peer.binarySHA256 == requirement.binarySHA256 else { throw SelfBuildPeerValidationError.wrongHash }
        if let requiredCDHash = requirement.cdHash {
            guard peer.cdHash == requiredCDHash else { throw SelfBuildPeerValidationError.wrongCDHash }
        }
        if !requirement.allowDebugSigned {
            guard !peer.debugSigned else { throw SelfBuildPeerValidationError.debugSignedRejected }
        }
    }

    public static func identity(
        helperName: String,
        path: String,
        version: String,
        cdHash: String? = nil,
        debugSigned: Bool = false,
        fileManager: FileManager = .default
    ) throws -> SelfBuildPeerIdentity {
        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        let fileAttributes = try fileManager.attributesOfItem(atPath: resolvedPath)
        let parentPath = (resolvedPath as NSString).deletingLastPathComponent
        let parentAttributes = try fileManager.attributesOfItem(atPath: parentPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath), options: [.mappedIfSafe])
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SelfBuildPeerIdentity(
            helperName: helperName,
            resolvedPath: resolvedPath,
            ownerUserID: (fileAttributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? getuid(),
            fileMode: (fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            parentMode: (parentAttributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            version: version,
            binarySHA256: hash,
            cdHash: cdHash,
            debugSigned: debugSigned
        )
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

public struct InstallManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var productName: String
    public var appVersion: String
    public var prefix: String
    public var installedAt: Date
    public var helpers: [SelfBuildPeerRequirement]

    public init(
        schemaVersion: Int = 1,
        productName: String = "AgenticFortress",
        appVersion: String,
        prefix: String,
        installedAt: Date,
        helpers: [SelfBuildPeerRequirement]
    ) {
        self.schemaVersion = schemaVersion
        self.productName = productName
        self.appVersion = appVersion
        self.prefix = prefix
        self.installedAt = installedAt
        self.helpers = helpers
    }

    public func requirement(for helperName: String) -> SelfBuildPeerRequirement? {
        helpers.first { $0.helperName == helperName }
    }
}

public struct LocalAuthenticationProof: Codable, Equatable, Sendable {
    public var manifestDigest: String
    public var actionClass: String
    public var reason: String
    public var authenticatedAt: Date

    public init(manifestDigest: String, actionClass: String, reason: String, authenticatedAt: Date) {
        self.manifestDigest = manifestDigest
        self.actionClass = actionClass
        self.reason = reason
        self.authenticatedAt = authenticatedAt
    }
}

public enum LocalAuthenticationError: Error, Equatable {
    case digestMismatch
    case actionClassMismatch
    case staleProof
}

public enum LocalAuthenticationGate {
    public static func validate(proof: LocalAuthenticationProof, manifest: DecisionManifest, maxAge: TimeInterval = 30, now: Date = Date()) throws {
        guard proof.manifestDigest == manifest.digest else { throw LocalAuthenticationError.digestMismatch }
        guard proof.actionClass == manifest.actionClass else { throw LocalAuthenticationError.actionClassMismatch }
        guard now.timeIntervalSince(proof.authenticatedAt) <= maxAge else { throw LocalAuthenticationError.staleProof }
    }

    public static func reason(for manifest: DecisionManifest) -> String {
        let delivery = manifest.secret.environmentName.map { "\(manifest.secret.delivery.rawValue):\($0)" } ?? manifest.secret.delivery.rawValue
        return [
            "AgenticFortress approval \(manifest.digest)",
            "Action: \(manifest.actionClass)",
            "Target: \(manifest.target.display)",
            "Workspace: \(manifest.workspace.display)",
            "Secret: \(manifest.secret.alias) via \(delivery)"
        ].joined(separator: "\n")
    }
}
