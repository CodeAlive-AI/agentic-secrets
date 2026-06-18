import Foundation

public enum CommandShimInstallStatus: String, Codable, Equatable, Sendable {
    case installed
    case notInstalled = "not installed"
    case blocked
    case helperUnavailable = "helper unavailable"
    case unknown
}

public enum CommandShimReplacementSafety: Equatable, Sendable {
    case absent
    case replaceable
    case directory
}

public enum CommandShimInstallationInspector {
    public static func status(
        name: String,
        installPrefix: URL?,
        helperRequirement: SelfBuildPeerRequirement? = nil
    ) -> CommandShimInstallStatus {
        guard let installPrefix else {
            return .unknown
        }

        let expectedShim = expectedShimBinary(installPrefix: installPrefix)
        let shimURL = shimDirectory(installPrefix: installPrefix).appendingPathComponent(name)
        let shimPresent = isPresent(shimURL)
        if shimPresent && !pointsToShimBinary(shimURL: shimURL, expectedShimBinary: expectedShim) {
            return .blocked
        }

        guard helperIsAvailable(expectedShim, requirement: helperRequirement) else {
            return .helperUnavailable
        }

        guard shimPresent else {
            return .notInstalled
        }

        return .installed
    }

    public static func inferredInstallPrefix(
        stateDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["AGENTIC_SECRETS_INSTALL_PREFIX"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let standardized = stateDirectory.standardizedFileURL
        guard standardized.lastPathComponent == "agentic-secrets",
              standardized.deletingLastPathComponent().lastPathComponent == "var" else {
            return nil
        }
        return standardized
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static func shimDirectory(installPrefix: URL) -> URL {
        installPrefix.appendingPathComponent("shims", isDirectory: true)
    }

    public static func expectedShimBinary(installPrefix: URL) -> URL {
        installPrefix.appendingPathComponent("bin/agentic-secrets-shim")
    }

    public static func pointsToShimBinary(shimURL: URL, expectedShimBinary: URL) -> Bool {
        guard isSymlink(shimURL) else {
            return false
        }

        let expected = expectedShimBinary.standardizedFileURL
        let expectedResolved = expectedShimBinary.resolvingSymlinksInPath().standardizedFileURL

        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: shimURL.path) else {
            return false
        }
        let destinationURL = normalizedSymlinkDestination(destination, relativeTo: shimURL.deletingLastPathComponent())
        let destinationStandard = destinationURL.standardizedFileURL
        return destinationStandard.path == expected.path
            || destinationStandard.path == expectedResolved.path
    }

    public static func replacementSafety(for url: URL) -> CommandShimReplacementSafety {
        if isSymlink(url) {
            return .replaceable
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .absent
        }
        return isDirectory.boolValue ? .directory : .replaceable
    }

    public static func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    private static func isPresent(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || isSymlink(url)
    }

    private static func helperIsAvailable(_ url: URL, requirement: SelfBuildPeerRequirement?) -> Bool {
        let resolvedPath = url.resolvingSymlinksInPath().path
        guard isPresent(url), FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            return false
        }
        guard let requirement else {
            return true
        }
        do {
            let identity = try SelfBuildPeerValidator.identity(
                helperName: "agentic-secrets-shim",
                path: url.path,
                version: requirement.minimumVersion
            )
            try SelfBuildPeerValidator.validate(peer: identity, requirement: requirement)
            return true
        } catch {
            return false
        }
    }

    private static func normalizedSymlinkDestination(_ destination: String, relativeTo directory: URL) -> URL {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        return directory.appendingPathComponent(destination)
    }
}
