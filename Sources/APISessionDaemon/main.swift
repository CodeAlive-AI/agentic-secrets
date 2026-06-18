import AgenticSecretsBroker
import Foundation

@main
struct AgenticSecretsAPISessionDaemon {
    static func main() throws {
        let (session, token) = APISessionAuthorizer().createSession(profile: BuiltInAPISessionProfiles.openAI, bindPort: 48177)
        try APISessionAuthorizer().authorize(session: session, token: token, method: "POST", path: "/v1/responses")
        print(try AgenticSecretsJSON.encodePretty(session))
    }
}

