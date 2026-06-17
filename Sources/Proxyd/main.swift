import AgenticFortressCore
import Foundation

@main
struct AgenticFortressProxyd {
    static func main() throws {
        let (session, token) = ProxyAuthorizer().createSession(profile: BuiltInProxyProfiles.openAI, bindPort: 48177)
        try ProxyAuthorizer().authorize(session: session, token: token, method: "POST", path: "/v1/responses")
        print(try AgenticFortressJSON.encodePretty(session))
    }
}

