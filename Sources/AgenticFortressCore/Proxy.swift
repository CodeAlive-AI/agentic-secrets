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

