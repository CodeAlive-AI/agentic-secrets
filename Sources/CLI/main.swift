import AgenticFortressCore
import Darwin
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
        case "ipc-conformance":
            print(try AgenticFortressJSON.encodePretty(IPCConformanceReport()))
        case "release-gates":
            print(try AgenticFortressJSON.encodePretty(ReleaseGateRunner().staticReport()))
        case "default-config":
            print(try ConfigurationLoader.encode(AgenticFortressConfig()))
        case "check-macos":
            let sdkMajor = args.first.flatMap(Int.init)
            print(try AgenticFortressJSON.encodePretty(MacOSCompatibility.runtimeReport(sdkMajor: sdkMajor)))
        case "adapter":
            try handleAdapter(args)
        case "cli":
            try handleCLI(args)
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
          agentic-fortress ipc-conformance
          agentic-fortress release-gates
          agentic-fortress default-config
          agentic-fortress check-macos 26
          agentic-fortress adapter list
          agentic-fortress adapter install-payload <payload.json> <registry.json>
          agentic-fortress adapter revoke <adapter-id> <registry.json>
          agentic-fortress cli register hcloud --env HCLOUD_TOKEN --secret-stdin
          agentic-fortress cli unregister hcloud --delete-secrets
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

    private static func handleCLI(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError.missingArgument("cli subcommand")
        }
        switch subcommand {
        case "register":
            guard args.count >= 2 else { throw CLIError.missingArgument("cli name") }
            let name = args[1]
            var passthrough = Array(args.dropFirst(2))
            guard passthrough.contains("--secret-stdin") || passthrough.contains("--secret-prompt") || passthrough.contains("--secrets-json-stdin") else {
                throw CLIError.missingArgument("--secret-stdin, --secret-prompt, or --secrets-json-stdin")
            }
            if !passthrough.contains("--target") {
                passthrough += ["--target", try resolveExecutable(name)]
            }
            if !passthrough.contains("--state-dir") {
                passthrough += ["--state-dir", defaultStateDirectory().path]
            }
            try runCoreCommand(["register-cli", "--name", name] + passthrough)
        case "unregister":
            guard args.count >= 2 else { throw CLIError.missingArgument("cli name") }
            let name = args[1]
            var passthrough = Array(args.dropFirst(2))
            if !passthrough.contains("--state-dir") {
                passthrough += ["--state-dir", defaultStateDirectory().path]
            }
            try runCoreCommand(["unregister-cli", "--name", name] + passthrough)
        default:
            throw CLIError.missingArgument("known cli subcommand")
        }
    }

    private static func runCoreCommand(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try coreDaemonPath())
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            exit(process.terminationStatus)
        }
    }

    private static func coreDaemonPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_FORTRESS_CORE_BINARY"], !override.isEmpty {
            return override
        }
        let invoked = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = invoked.deletingLastPathComponent().appendingPathComponent("agentic-fortressd-core")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling.path
        }
        throw CLIError.missingArgument("agentic-fortressd-core sibling binary or AGENTIC_FORTRESS_CORE_BINARY")
    }

    private static func defaultStateDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_FORTRESS_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let invoked = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let components = invoked.pathComponents
        if let applicationsIndex = components.lastIndex(of: "Applications"), applicationsIndex > 0 {
            let prefix = URL(fileURLWithPath: "/" + components[1..<applicationsIndex].joined(separator: "/"), isDirectory: true)
            return prefix.appendingPathComponent("var/agentic-fortress", isDirectory: true)
        }
        return AgenticFortressStateLayout.defaultStateDirectory()
    }

    private static func resolveExecutable(_ name: String) throws -> String {
        guard !name.contains("/") else {
            guard FileManager.default.isExecutableFile(atPath: name) else {
                throw CLIError.missingArgument("executable target for \(name)")
            }
            return name
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError.missingArgument("--target for \(name)")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw CLIError.missingArgument("--target for \(name)")
        }
        return output
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
