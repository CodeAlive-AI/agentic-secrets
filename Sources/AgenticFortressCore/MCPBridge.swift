import Foundation

public struct MCPUpstreamProfile: Codable, Equatable, Sendable {
    public var name: String
    public var origin: URL
    public var authorizationHeaderName: String
    public var allowedPathPrefixes: [String]
    public var allowCrossOriginRedirects: Bool

    public init(name: String, origin: URL, authorizationHeaderName: String = "Authorization", allowedPathPrefixes: [String] = ["/"], allowCrossOriginRedirects: Bool = false) {
        self.name = name
        self.origin = origin
        self.authorizationHeaderName = authorizationHeaderName
        self.allowedPathPrefixes = allowedPathPrefixes
        self.allowCrossOriginRedirects = allowCrossOriginRedirects
    }
}

public enum MCPBridgeError: Error, Equatable {
    case unpinnedProfile
    case pathBlocked
    case crossOriginRedirectBlocked
    case invalidSessionID
}

public struct MCPBridgeSession: Codable, Equatable, Sendable {
    public var profile: MCPUpstreamProfile
    public var mcpSessionID: String?

    public init(profile: MCPUpstreamProfile, mcpSessionID: String? = nil) {
        self.profile = profile
        self.mcpSessionID = mcpSessionID
    }

    public func requestHeaders(bearerToken: String) -> [String: String] {
        var headers = [profile.authorizationHeaderName: "Bearer \(bearerToken)"]
        if let mcpSessionID {
            headers["MCP-Session-Id"] = mcpSessionID
        }
        return headers
    }

    public func updatingFromResponse(headers: [String: String]) throws -> MCPBridgeSession {
        var next = self
        if let id = headers.first(where: { $0.key.lowercased() == "mcp-session-id" })?.value {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPBridgeError.invalidSessionID
            }
            next.mcpSessionID = id
        }
        return next
    }

    public func validate(path: String, redirect: URL? = nil) throws {
        guard profile.allowedPathPrefixes.contains(where: { path.hasPrefix($0) }) else {
            throw MCPBridgeError.pathBlocked
        }
        if let redirect, !profile.allowCrossOriginRedirects {
            guard redirect.scheme == profile.origin.scheme,
                  redirect.host == profile.origin.host,
                  redirect.port == profile.origin.port else {
                throw MCPBridgeError.crossOriginRedirectBlocked
            }
        }
    }
}

public struct MCPConformanceCase: Codable, Equatable, Sendable {
    public var name: String
    public var required: Bool
}

public enum MCPConformanceSuite {
    public static let required: [MCPConformanceCase] = [
        .init(name: "session initialization", required: true),
        .init(name: "MCP-Session-Id propagation", required: true),
        .init(name: "401 WWW-Authenticate handling", required: true),
        .init(name: "404 session reset", required: true),
        .init(name: "streaming response", required: true),
        .init(name: "backpressure", required: true),
        .init(name: "client cancellation", required: true),
        .init(name: "server reconnect", required: true),
        .init(name: "large message", required: true),
        .init(name: "invalid JSON-RPC", required: true),
        .init(name: "redaction", required: true),
        .init(name: "no-body-logging", required: true),
        .init(name: "cross-origin redirect block", required: true),
        .init(name: "profile pinning", required: true)
    ]
}

