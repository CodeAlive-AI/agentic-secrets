import AgenticSecretsBroker
import Foundation

@main
struct AgenticSecretsMCPDaemon {
    static func main() throws {
        let profile = MCPUpstreamProfile(name: "example", origin: URL(string: "https://mcp.example.test")!, allowedPathPrefixes: ["/mcp"])
        var session = MCPBridgeSession(profile: profile)
        try session.validate(path: "/mcp")
        session = try session.updatingFromResponse(headers: ["MCP-Session-Id": "sess_123"])
        let headers = session.requestHeaders(bearerToken: "not-real-token")
        print(try AgenticSecretsJSON.encodePretty([
            "profile": profile.name,
            "session_id": session.mcpSessionID ?? "",
            "authorization_header": headers["Authorization"] == nil ? "missing" : "present-redacted"
        ]))
    }
}

