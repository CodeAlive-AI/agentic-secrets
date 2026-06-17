import AgenticFortressCore
import Foundation

@main
struct AgenticFortressCLI {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }
        args.removeFirst()

        switch command {
        case "profiles":
            print(try AgenticFortressJSON.encodePretty(BoundedSafetyProfiles.all))
        case "invariants":
            print(try AgenticFortressJSON.encodePretty(AgenticFortressInvariant.allCases))
        case "classify":
            guard let executable = args.first else {
                throw CLIError.missingArgument("executable")
            }
            let normalized = CommandClassifier().classify(executableName: executable, arguments: Array(args.dropFirst()))
            print(try AgenticFortressJSON.encodePretty(normalized))
        case "manifest":
            guard let executable = args.first else {
                throw CLIError.missingArgument("executable")
            }
            let normalized = CommandClassifier().classify(executableName: executable, arguments: Array(args.dropFirst()))
            let target = TargetAssessor().synthetic(path: "/opt/homebrew/bin/\(executable)", identity: "sha256:\(shortDigest(executable))")
            let intent = DeliveryIntent(
                flow: .cliEnv,
                secretAlias: "cloud.hcloud.dev",
                delivery: .env,
                environmentName: "HCLOUD_TOKEN",
                workspace: FileManager.default.currentDirectoryPath,
                parentApp: ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "unknown"
            )
            let manifest = DecisionManifestFactory().make(command: normalized, intent: intent, target: target)
            print(try AgenticFortressJSON.encodePretty(manifest))
        case "proxy-session":
            let profile = BuiltInProxyProfiles.openAI
            let (session, token) = ProxyAuthorizer().createSession(profile: profile, bindPort: 48177)
            let payload = ["session": try AgenticFortressJSON.encodePretty(session), "proxy_token_preview": "sha256:\(shortDigest(token))"]
            print(try AgenticFortressJSON.encodePretty(payload))
        case "mcp-conformance":
            print(try AgenticFortressJSON.encodePretty(MCPConformanceSuite.required))
        case "release-gates":
            print(try AgenticFortressJSON.encodePretty(ReleaseGateRunner().staticReport()))
        case "default-config":
            print(try ConfigurationLoader.encode(AgenticFortressConfig()))
        case "check-macos":
            let sdkMajor = args.first.flatMap(Int.init)
            print(try AgenticFortressJSON.encodePretty(MacOSCompatibility.runtimeReport(sdkMajor: sdkMajor)))
        case "adapter":
            try handleAdapter(args)
        case "redact":
            print(Redactor().redact(args.joined(separator: " ")))
        default:
            printUsage()
        }
    }

    private static func printUsage() {
        print("""
        AgenticFortress

        Usage:
          agentic-fortress profiles
          agentic-fortress invariants
          agentic-fortress classify hcloud server list
          agentic-fortress manifest hcloud server list
          agentic-fortress proxy-session
          agentic-fortress mcp-conformance
          agentic-fortress release-gates
          agentic-fortress default-config
          agentic-fortress check-macos 26
          agentic-fortress adapter list
          agentic-fortress adapter install-payload <payload.json> <registry.json>
          agentic-fortress adapter revoke <adapter-id> <registry.json>
          agentic-fortress redact "OPENAI_API_KEY=..."
        """)
    }

    private static func handleAdapter(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError.missingArgument("adapter subcommand")
        }
        switch subcommand {
        case "list":
            let entries = [
                AdapterRegistryEntry(payload: BuiltInAdapterPacks.hcloud, installedAt: Date(timeIntervalSince1970: 0)),
                AdapterRegistryEntry(payload: BuiltInAdapterPacks.githubCLI, installedAt: Date(timeIntervalSince1970: 0)),
                AdapterRegistryEntry(payload: BuiltInAdapterPacks.terraform, installedAt: Date(timeIntervalSince1970: 0))
            ]
            print(try AgenticFortressJSON.encodePretty(AdapterRegistryDocument(entries: entries)))
        case "install-payload":
            guard args.count >= 3 else { throw CLIError.missingArgument("payload.json registry.json") }
            let payload = try JSONDecoder().decode(AdapterPackPayload.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            try AdapterRegistryStore(url: URL(fileURLWithPath: args[2])).install(payload: payload)
            print("installed \(payload.adapterID)@\(payload.adapterVersion)")
        case "revoke":
            guard args.count >= 3 else { throw CLIError.missingArgument("adapter-id registry.json") }
            try AdapterRegistryStore(url: URL(fileURLWithPath: args[2])).revoke(adapterID: args[1])
            print("revoked \(args[1])")
        default:
            throw CLIError.missingArgument("known adapter subcommand")
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case missingArgument(String)

    var description: String {
        switch self {
        case .missingArgument(let argument):
            "Missing argument: \(argument)"
        }
    }
}
