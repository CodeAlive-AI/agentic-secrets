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
