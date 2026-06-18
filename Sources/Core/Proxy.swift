import Foundation

public struct ProxyProfile: Codable, Equatable, Sendable {
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

public struct ProxySession: Codable, Equatable, Sendable {
    public var id: String
    public var profile: ProxyProfile
    public var localEndpoint: URL
    public var tokenHash: String
    public var expiresAt: Date
}

public enum ProxyError: Error, Equatable {
    case missingToken
    case tokenMismatch
    case expired
    case methodBlocked
    case pathBlocked
    case crossOriginRedirectBlocked
    case bodyLoggingDisabled
}

public struct ProxyHTTPRequest: Codable, Equatable, Sendable {
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

public struct ProxyUpstreamRequest: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var auditMetadata: [String: String]
}

public struct ProxyAuthorizer: Sendable {
    public init() {}

    public func createSession(profile: ProxyProfile, bindPort: Int, token: String = UUID().uuidString, now: Date = Date()) -> (ProxySession, token: String) {
        let endpoint = URL(string: "http://127.0.0.1:\(bindPort)/\(profile.name)/session/\(shortDigest(token, length: 10))")!
        let session = ProxySession(id: "px_" + shortDigest(UUID().uuidString, length: 16), profile: profile, localEndpoint: endpoint, tokenHash: stableDigest(token), expiresAt: now.addingTimeInterval(profile.tokenTTLSeconds))
        return (session, token)
    }

    public func authorize(session: ProxySession, token: String?, method: String, path: String, now: Date = Date()) throws {
        guard let token else { throw ProxyError.missingToken }
        guard stableDigest(token) == session.tokenHash else { throw ProxyError.tokenMismatch }
        guard session.expiresAt >= now else { throw ProxyError.expired }
        guard session.profile.allowedMethods.contains(method.uppercased()) else { throw ProxyError.methodBlocked }
        guard session.profile.allowedPathPrefixes.contains(where: { path.hasPrefix($0) }) else { throw ProxyError.pathBlocked }
    }

    public func validateRedirect(session: ProxySession, location: URL) throws {
        guard location.scheme == session.profile.upstreamOrigin.scheme,
              location.host == session.profile.upstreamOrigin.host,
              location.port == session.profile.upstreamOrigin.port else {
            throw ProxyError.crossOriginRedirectBlocked
        }
    }
}

public struct ProxyRuntime: Sendable {
    private let authorizer: ProxyAuthorizer
    private let redactor: Redactor

    public init(authorizer: ProxyAuthorizer = ProxyAuthorizer(), redactor: Redactor = Redactor()) {
        self.authorizer = authorizer
        self.redactor = redactor
    }

    public func prepareUpstreamRequest(session: ProxySession, request: ProxyHTTPRequest, upstreamSecret: SecretMaterial, now: Date = Date()) throws -> ProxyUpstreamRequest {
        try authorizer.authorize(session: session, token: request.sessionToken, method: request.method, path: request.path, now: now)
        let upstreamURL = session.profile.upstreamOrigin.appendingPathComponent(String(request.path.drop(while: { $0 == "/" })))
        var headers = request.headers
        headers["Authorization"] = upstreamSecret.withUTF8String { "Bearer \($0)" }
        headers.removeValue(forKey: "AGENTIC_FORTRESS_PROXY_TOKEN")
        let metadata = [
            "profile": session.profile.name,
            "method": request.method.uppercased(),
            "path": request.path,
            "upstream": "\(session.profile.upstreamOrigin.scheme ?? "")://\(session.profile.upstreamOrigin.host ?? "")",
            "authorization": "present-redacted"
        ].mapValues { redactor.redact($0) }
        return ProxyUpstreamRequest(url: upstreamURL, method: request.method.uppercased(), headers: headers, body: request.body, auditMetadata: metadata)
    }

    public func bodyForAudit(_ body: Data?) throws -> String? {
        guard body == nil else {
            throw ProxyError.bodyLoggingDisabled
        }
        return nil
    }
}

public enum BuiltInProxyProfiles {
    public static let openAI = ProxyProfile(
        name: "openai",
        upstreamOrigin: URL(string: "https://api.openai.com")!,
        allowedPathPrefixes: ["/v1/"],
        allowedMethods: ["GET", "POST"],
        secretAlias: "ai.openai.dev"
    )

    public static let anthropic = ProxyProfile(
        name: "anthropic",
        upstreamOrigin: URL(string: "https://api.anthropic.com")!,
        allowedPathPrefixes: ["/v1/"],
        allowedMethods: ["GET", "POST"],
        secretAlias: "ai.anthropic.dev"
    )
}
