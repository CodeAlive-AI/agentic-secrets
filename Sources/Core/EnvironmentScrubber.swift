import Foundation

public enum EnvironmentScrubError: Error, Equatable, CustomStringConvertible {
    case targetAlreadyPresent(String)

    public var description: String {
        switch self {
        case .targetAlreadyPresent(let name):
            "Ambient \(name) already exists; remove it before using env delivery."
        }
    }
}

public struct EnvironmentScrubber: Sendable {
    private let blockedExactNames: Set<String> = [
        "BWS_ACCESS_TOKEN",
        "BW_SESSION",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "GEMINI_API_KEY",
        "HCLOUD_TOKEN",
        "STRIPE_API_KEY",
        "GITHUB_TOKEN",
        "GH_TOKEN"
    ]

    private let secretFragments = ["TOKEN", "SECRET", "PASSWORD", "PRIVATE_KEY", "API_KEY", "ACCESS_KEY", "AUTHORIZATION"]

    public init() {}

    public func scrub(parent: [String: String], targetEnvironmentName: String, injectedValue: String) throws -> [String: String] {
        if parent[targetEnvironmentName] != nil {
            throw EnvironmentScrubError.targetAlreadyPresent(targetEnvironmentName)
        }

        var clean: [String: String] = [:]
        for (key, value) in parent {
            if key == targetEnvironmentName { continue }
            if blockedExactNames.contains(key) { continue }
            if looksSecretLike(key) { continue }
            clean[key] = value
        }
        clean[targetEnvironmentName] = injectedValue
        return clean
    }

    public func proxyEnvironment(parent: [String: String], endpoint: URL, token: String, apiKeyName: String = "OPENAI_API_KEY", baseURLName: String = "OPENAI_BASE_URL") -> [String: String] {
        var clean = parent.filter { !looksSecretLike($0.key) && !blockedExactNames.contains($0.key) }
        clean[baseURLName] = endpoint.absoluteString
        clean[apiKeyName] = "agentic-fortress-proxy-placeholder"
        clean["AGENTIC_FORTRESS_PROXY_TOKEN"] = token
        return clean
    }

    private func looksSecretLike(_ key: String) -> Bool {
        let upper = key.uppercased()
        return secretFragments.contains { upper.contains($0) }
    }
}
