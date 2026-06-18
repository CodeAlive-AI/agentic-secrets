import Foundation

public struct MCPUpstreamProfile: Codable, Equatable, Sendable {
    public var name: String
    public var origin: URL
    public var authorizationHeaderName: String
    public var secretAlias: String?
    public var allowedPathPrefixes: [String]
    public var allowCrossOriginRedirects: Bool

    public init(name: String, origin: URL, authorizationHeaderName: String = "Authorization", secretAlias: String? = nil, allowedPathPrefixes: [String] = ["/"], allowCrossOriginRedirects: Bool = false) {
        self.name = name
        self.origin = origin
        self.authorizationHeaderName = authorizationHeaderName
        self.secretAlias = secretAlias
        self.allowedPathPrefixes = allowedPathPrefixes
        self.allowCrossOriginRedirects = allowCrossOriginRedirects
    }
}

public enum MCPBridgeError: Error, Equatable {
    case unpinnedProfile
    case pathBlocked
    case crossOriginRedirectBlocked
    case invalidSessionID
    case invalidJSONRPC
    case bodyLoggingDisabled
}

public struct JSONRPCMessage: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: String?
    public var method: String?
    public var params: [String: String]?

    public init(jsonrpc: String = "2.0", id: String? = nil, method: String? = nil, params: [String: String]? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum JSONRPCFramer {
    public static func decodeLine(_ line: String) throws -> JSONRPCMessage {
        guard let data = line.data(using: .utf8) else {
            throw MCPBridgeError.invalidJSONRPC
        }
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)
        guard message.jsonrpc == "2.0", message.method != nil || message.id != nil else {
            throw MCPBridgeError.invalidJSONRPC
        }
        return message
    }

    public static func encodeLine(_ message: JSONRPCMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(message), as: UTF8.self) + "\n"
    }
}

public struct MCPHTTPBridgeRequest: Equatable, Sendable {
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public var auditMetadata: [String: String]
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

    public func prepareHTTPRequest(path: String, message: JSONRPCMessage, bearerToken: String) throws -> MCPHTTPBridgeRequest {
        try validate(path: path)
        let body = try JSONEncoder().encode(message)
        var headers = requestHeaders(bearerToken: bearerToken)
        headers["Content-Type"] = "application/json"
        return MCPHTTPBridgeRequest(
            path: path,
            headers: headers,
            body: body,
            auditMetadata: [
                "profile": profile.name,
                "path": path,
                "method": message.method ?? "response",
                "body": "disabled",
                "authorization": "present-redacted"
            ]
        )
    }

    public func bodyForAudit(_ body: Data?) throws -> String? {
        guard body == nil else {
            throw MCPBridgeError.bodyLoggingDisabled
        }
        return nil
    }

    public func responseMetadata(statusCode: Int, headers: [String: String]) -> [String: String] {
        var metadata = ["status": "\(statusCode)"]
        if statusCode == 401 {
            metadata["auth_challenge"] = headers.first(where: { $0.key.lowercased() == "www-authenticate" })?.value ?? "missing"
        }
        if statusCode == 404 {
            metadata["session_reset"] = "true"
        }
        return metadata
    }

    public func cancellationMessage(id: String) -> JSONRPCMessage {
        JSONRPCMessage(id: id, method: "notifications/cancelled", params: ["requestId": id])
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
