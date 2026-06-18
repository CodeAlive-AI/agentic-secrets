import Foundation

struct AppSemanticVersion: Comparable, Equatable, Sendable {
    var components: [Int]

    init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = trimmed.range(
            of: #"\d+(?:\.\d+){0,2}"#,
            options: .regularExpression
        ).map { String(trimmed[$0]) } ?? "0.0.0"
        var parts = numeric.split(separator: ".").compactMap { Int($0) }
        while parts.count < 3 {
            parts.append(0)
        }
        self.components = Array(parts.prefix(3))
    }

    init(_ osVersion: OperatingSystemVersion) {
        self.components = [osVersion.majorVersion, osVersion.minorVersion, osVersion.patchVersion]
    }

    static func < (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) {
            if left < right { return true }
            if left > right { return false }
        }
        return false
    }
}

struct AppUpdateRelease: Codable, Equatable, Identifiable, Sendable {
    var tagName: String
    var name: String
    var prerelease: Bool
    var htmlURL: URL
    var body: String

    var id: String { htmlURL.absoluteString }

    var version: AppSemanticVersion {
        AppSemanticVersion(tagName.isEmpty ? name : tagName)
    }

    var versionLabel: String {
        let parsed = version.components.map(String.init).joined(separator: ".")
        return parsed == "0.0.0" ? name : parsed
    }

    var displayName: String {
        name.isEmpty ? "Agentic Secrets \(versionLabel)" : name
    }

    var critical: Bool {
        body.localizedCaseInsensitiveContains("Critical Security Update")
    }

    var minimumOSVersion: AppSemanticVersion {
        guard let marker = body.range(of: "Minimum macOS Version", options: [.caseInsensitive]) else {
            return AppSemanticVersion("14.0.0")
        }
        let searchRange = marker.upperBound..<body.endIndex
        guard let numberStart = body.rangeOfCharacter(from: .decimalDigits, range: searchRange)?.lowerBound else {
            return AppSemanticVersion("14.0.0")
        }
        let numberEnd = body.rangeOfCharacter(
            from: CharacterSet(charactersIn: "0123456789.").inverted,
            range: numberStart..<body.endIndex
        )?.lowerBound ?? body.endIndex
        return AppSemanticVersion(String(body[numberStart..<numberEnd]))
    }
}

protocol AppUpdateChecking: Sendable {
    func availableUpdate(
        currentVersion: String,
        osVersion: OperatingSystemVersion
    ) async throws -> AppUpdateRelease?
}

struct GitHubAppUpdateChecker: AppUpdateChecking {
    var releasesURL: URL = URL(string: "https://api.github.com/repos/CodeAlive-AI/agentic-secrets/releases")!
    var session: URLSession = .shared

    func availableUpdate(
        currentVersion: String,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) async throws -> AppUpdateRelease? {
        var request = URLRequest(url: releasesURL)
        request.setValue("AgenticSecrets/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppUpdateError.httpStatus(http.statusCode)
        }
        let releases = try JSONDecoder().decode([GitHubReleaseDTO].self, from: data).map(AppUpdateRelease.init)
        return Self.evaluate(
            releases: releases,
            currentVersion: AppSemanticVersion(currentVersion),
            osVersion: AppSemanticVersion(osVersion)
        )
    }

    static func evaluate(
        releases: [AppUpdateRelease],
        currentVersion: AppSemanticVersion,
        osVersion: AppSemanticVersion
    ) -> AppUpdateRelease? {
        releases
            .filter { !$0.prerelease }
            .filter { $0.minimumOSVersion <= osVersion }
            .sorted { $0.version < $1.version }
            .reversed()
            .first { $0.version > currentVersion }
    }
}

enum AppUpdateError: Error, CustomStringConvertible {
    case httpStatus(Int)

    var description: String {
        switch self {
        case .httpStatus(let status):
            "GitHub releases request failed with HTTP \(status)."
        }
    }
}

private struct GitHubReleaseDTO: Decodable {
    var tagName: String
    var name: String?
    var prerelease: Bool
    var draft: Bool
    var htmlURL: URL
    var body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case prerelease
        case draft
        case htmlURL = "html_url"
        case body
    }
}

private extension AppUpdateRelease {
    init(_ release: GitHubReleaseDTO) {
        self.init(
            tagName: release.tagName,
            name: release.name ?? release.tagName,
            prerelease: release.prerelease || release.draft,
            htmlURL: release.htmlURL,
            body: release.body ?? ""
        )
    }
}
