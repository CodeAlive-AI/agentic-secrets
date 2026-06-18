import Foundation

public struct APISessionProfile: Codable, Equatable, Sendable {
    public var name: String
    public var upstreamOrigin: URL
    public var allowedPathPrefixes: [String]
    public var allowedMethods: Set<String>
    public var secretAlias: String
    public var tokenTTLSeconds: TimeInterval

    public init(name: String, upstreamOrigin: URL, allowedPathPrefixes: [String], allowedMethods: Set<String>, secretAlias: String, tokenTTLSeconds: TimeInterval = 900) {
        self.name = name
        self.upstreamOrigin = upstreamOrigin
        self.allowedPathPrefixes = allowedPathPrefixes
        self.allowedMethods = allowedMethods
        self.secretAlias = secretAlias
        self.tokenTTLSeconds = tokenTTLSeconds
    }

    enum CodingKeys: String, CodingKey {
        case name
        case upstreamOrigin
        case allowedPathPrefixes
        case allowedMethods
        case secretAlias
        case tokenTTLSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.upstreamOrigin = try container.decode(URL.self, forKey: .upstreamOrigin)
        self.allowedPathPrefixes = try container.decode([String].self, forKey: .allowedPathPrefixes)
        self.allowedMethods = Set(try container.decode([String].self, forKey: .allowedMethods))
        self.secretAlias = try container.decode(String.self, forKey: .secretAlias)
        self.tokenTTLSeconds = try container.decode(TimeInterval.self, forKey: .tokenTTLSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(upstreamOrigin, forKey: .upstreamOrigin)
        try container.encode(allowedPathPrefixes, forKey: .allowedPathPrefixes)
        try container.encode(allowedMethods.sorted(), forKey: .allowedMethods)
        try container.encode(secretAlias, forKey: .secretAlias)
        try container.encode(tokenTTLSeconds, forKey: .tokenTTLSeconds)
    }
}

public struct APISession: Codable, Equatable, Sendable {
    public var id: String
    public var profile: APISessionProfile
    public var localEndpoint: URL
    public var tokenHash: String
    public var expiresAt: Date
}

public enum APISessionError: Error, Equatable {
    case missingToken
    case tokenMismatch
    case expired
    case methodBlocked
    case pathBlocked
    case crossOriginRedirectBlocked
    case bodyLoggingDisabled
}

public struct APISessionHTTPRequest: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data?
    public var sessionToken: String?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil, sessionToken: String?) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.sessionToken = sessionToken
    }
}

public struct APISessionUpstreamRequest: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var auditMetadata: [String: String]
}

public struct APISessionAuthorizer: Sendable {
    public init() {}

    public func createSession(profile: APISessionProfile, bindPort: Int, token: String = UUID().uuidString, now: Date = Date()) -> (APISession, token: String) {
        let endpoint = URL(string: "http://127.0.0.1:\(bindPort)/\(profile.name)/session/\(shortDigest(token, length: 10))")!
        let session = APISession(id: "px_" + shortDigest(UUID().uuidString, length: 16), profile: profile, localEndpoint: endpoint, tokenHash: stableDigest(token), expiresAt: now.addingTimeInterval(profile.tokenTTLSeconds))
        return (session, token)
    }

    public func authorize(session: APISession, token: String?, method: String, path: String, now: Date = Date()) throws {
        guard let token else { throw APISessionError.missingToken }
        guard stableDigest(token) == session.tokenHash else { throw APISessionError.tokenMismatch }
        guard session.expiresAt >= now else { throw APISessionError.expired }
        guard session.profile.allowedMethods.contains(method.uppercased()) else { throw APISessionError.methodBlocked }
        guard session.profile.allowedPathPrefixes.contains(where: { path.hasPrefix($0) }) else { throw APISessionError.pathBlocked }
    }

    public func validateRedirect(session: APISession, location: URL) throws {
        guard location.scheme == session.profile.upstreamOrigin.scheme,
              location.host == session.profile.upstreamOrigin.host,
              location.port == session.profile.upstreamOrigin.port else {
            throw APISessionError.crossOriginRedirectBlocked
        }
    }
}

public struct APISessionRuntime: Sendable {
    private let authorizer: APISessionAuthorizer
    private let redactor: Redactor

    public init(authorizer: APISessionAuthorizer = APISessionAuthorizer(), redactor: Redactor = Redactor()) {
        self.authorizer = authorizer
        self.redactor = redactor
    }

    public func prepareUpstreamRequest(session: APISession, request: APISessionHTTPRequest, upstreamSecret: SecretMaterial, now: Date = Date()) throws -> APISessionUpstreamRequest {
        try authorizer.authorize(session: session, token: request.sessionToken, method: request.method, path: request.path, now: now)
        let upstreamURL = session.profile.upstreamOrigin.appendingPathComponent(String(request.path.drop(while: { $0 == "/" })))
        var headers = request.headers
        headers["Authorization"] = upstreamSecret.withUTF8String { "Bearer \($0)" }
        headers.removeValue(forKey: "AGENTIC_SECRETS_PROXY_TOKEN")
        let metadata = [
            "profile": session.profile.name,
            "method": request.method.uppercased(),
            "path": request.path,
            "upstream": "\(session.profile.upstreamOrigin.scheme ?? "")://\(session.profile.upstreamOrigin.host ?? "")",
            "authorization": "present-redacted"
        ].mapValues { redactor.redact($0) }
        return APISessionUpstreamRequest(url: upstreamURL, method: request.method.uppercased(), headers: headers, body: request.body, auditMetadata: metadata)
    }

    public func bodyForAudit(_ body: Data?) throws -> String? {
        guard body == nil else {
            throw APISessionError.bodyLoggingDisabled
        }
        return nil
    }
}

public enum BuiltInAPISessionProfiles {
    public static let openAI = APISessionProfile(
        name: "openai",
        upstreamOrigin: URL(string: "https://api.openai.com")!,
        allowedPathPrefixes: ["/v1/"],
        allowedMethods: ["GET", "POST"],
        secretAlias: "ai.openai.dev"
    )

    public static let anthropic = APISessionProfile(
        name: "anthropic",
        upstreamOrigin: URL(string: "https://api.anthropic.com")!,
        allowedPathPrefixes: ["/v1/"],
        allowedMethods: ["GET", "POST"],
        secretAlias: "ai.anthropic.dev"
    )
}
