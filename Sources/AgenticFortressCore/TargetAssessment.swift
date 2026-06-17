import CryptoKit
import Foundation

public enum TOCTOUTier: String, Codable, Sendable {
    case tier0RaceMinimized = "tier-0-race-minimized"
    case tier1HardenedPath = "tier-1-hardened-path"
    case tier2SealedTargetCache = "tier-2-sealed-target-cache"
    case tier3PrivilegedSealedStore = "tier-3-privileged-sealed-store"
}

public struct TargetAssessment: Codable, Equatable, Sendable {
    public var resolvedPath: String
    public var identity: String
    public var kind: String
    public var trustLevel: String
    public var tier: TOCTOUTier
    public var warnings: [String]
}

public enum TargetAssessmentError: Error, Equatable {
    case missing
    case notRegularFile
    case worldWritableParent(String)
    case groupWritableParent(String)
}

public struct TargetAssessor {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func assess(path: String, tier: TOCTOUTier = .tier0RaceMinimized) throws -> TargetAssessment {
        let resolved = (path as NSString).resolvingSymlinksInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            throw TargetAssessmentError.missing
        }
        guard !isDirectory.boolValue else {
            throw TargetAssessmentError.notRegularFile
        }
        let parent = (resolved as NSString).deletingLastPathComponent
        let attrs = try fileManager.attributesOfItem(atPath: parent)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if mode & 0o002 != 0 {
            throw TargetAssessmentError.worldWritableParent(parent)
        }
        var warnings: [String] = []
        if mode & 0o020 != 0 {
            warnings.append("Parent directory is group-writable; Tier 0 does not make strong TOCTOU claims.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: resolved), options: [.mappedIfSafe])
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return TargetAssessment(resolvedPath: resolved, identity: "sha256:\(hash)", kind: "local-cli", trustLevel: "pragmatic-local-recipe", tier: tier, warnings: warnings)
    }

    public func synthetic(path: String, identity: String = "sha256:test") -> TargetAssessment {
        TargetAssessment(resolvedPath: path, identity: identity, kind: "local-cli", trustLevel: "test", tier: .tier0RaceMinimized, warnings: [])
    }
}

public struct SealedTargetManifest: Codable, Equatable, Sendable {
    public var sourcePath: String
    public var sourceHash: String
    public var approvedAt: Date
    public var approvedBy: String
    public var formula: String?
    public var version: String?
}

public struct SealedTargetCache: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public func manifestPath(for identity: String) -> URL {
        root.appendingPathComponent(identity.replacingOccurrences(of: ":", with: "-")).appendingPathComponent("manifest.json")
    }

    public func plannedLocation(for identity: String) -> URL {
        root.appendingPathComponent(identity.replacingOccurrences(of: ":", with: "-"))
    }
}
