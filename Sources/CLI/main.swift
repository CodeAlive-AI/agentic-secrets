import AgenticSecretsBroker
import Darwin
import Foundation

@main
struct AgenticSecretsCLI {
    static func main() {
        do {
            try run()
        } catch {
            fputs("Error: \(error)\nRun `agentic-secrets` for usage.\n", stderr)
            exit(64)
        }
    }

    private static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }
        args.removeFirst()

        switch command {
        case "profiles":
            print(try AgenticSecretsJSON.encodePretty(DeliveryContracts.all))
        case "invariants":
            print(try AgenticSecretsJSON.encodePretty(SecurityInvariant.allCases))
        case "classify":
            guard let executable = args.first else {
                throw CLIError.missingArgument("executable")
            }
            let normalized = CommandClassifier().classify(executableName: executable, arguments: Array(args.dropFirst()))
            print(try AgenticSecretsJSON.encodePretty(normalized))
        case "manifest":
            guard let executable = args.first else {
                throw CLIError.missingArgument("executable")
            }
            let normalized = CommandClassifier().classify(executableName: executable, arguments: Array(args.dropFirst()))
            let target = TargetAssessor().synthetic(path: "/opt/homebrew/bin/\(executable)", identity: "sha256:\(shortDigest(executable))")
            let origin = ProcessOriginHint.current()
            let intent = DeliveryRequest(
                flow: .cliEnv,
                secretAlias: "cloud.hcloud.dev",
                delivery: .env,
                environmentName: "HCLOUD_TOKEN",
                workspace: FileManager.default.currentDirectoryPath,
                originHint: origin.displayName,
                provenanceConfidence: origin.provenanceConfidence
            )
            let manifest = DeliveryDecisionManifestFactory().make(command: normalized, intent: intent, target: target)
            print(try AgenticSecretsJSON.encodePretty(manifest))
        case "api-session":
            let profile = BuiltInAPISessionProfiles.openAI
            let (session, token) = APISessionAuthorizer().createSession(profile: profile, bindPort: 48177)
            let payload = ["session": try AgenticSecretsJSON.encodePretty(session), "api_session_token_preview": "sha256:\(shortDigest(token))"]
            print(try AgenticSecretsJSON.encodePretty(payload))
        case "mcp-conformance":
            print(try AgenticSecretsJSON.encodePretty(MCPConformanceSuite.required))
        case "ipc-conformance":
            print(try AgenticSecretsJSON.encodePretty(IPCConformanceReport()))
        case "release-gates":
            print(try AgenticSecretsJSON.encodePretty(ReleaseGateRunner().staticReport()))
        case "default-config":
            print(try ConfigurationLoader.encode(AgenticSecretsConfiguration()))
        case "check-macos":
            let sdkMajor = args.first.flatMap(Int.init)
            print(try AgenticSecretsJSON.encodePretty(MacOSCompatibility.runtimeReport(sdkMajor: sdkMajor)))
        case "adapter":
            try handleAdapter(args)
        case "cli":
            try handleCLI(args)
        case "redact":
            print(Redactor().redact(args.joined(separator: " ")))
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func printUsage() {
        print("""
        AgenticSecrets

        Usage:
          agentic-secrets profiles
          agentic-secrets invariants
          agentic-secrets classify hcloud server list
          agentic-secrets manifest hcloud server list
          agentic-secrets api-session
          agentic-secrets mcp-conformance
          agentic-secrets ipc-conformance
          agentic-secrets release-gates
          agentic-secrets default-config
          agentic-secrets check-macos 26
          agentic-secrets adapter list
          agentic-secrets adapter install-payload <payload.json> <registry.json>
          agentic-secrets command policy pack revoke <adapter-id> <registry.json>
          agentic-secrets cli register hcloud --env HCLOUD_TOKEN --secret-stdin
          agentic-secrets cli run hcloud -- server list
          agentic-secrets cli run hcloud --authorization-mode always -- server list
          agentic-secrets cli run hcloud --authorization-mode remember-24h -- server list
          agentic-secrets cli run hcloud --authorization-mode once -- server delete prod-db-01
          agentic-secrets cli run hcloud --authorization-mode short --delivery-grant-ttl-seconds 300 -- server list
          agentic-secrets cli shim install hcloud --configure-shell
          agentic-secrets cli trust-refresh hcloud
          agentic-secrets cli unregister hcloud --delete-secrets
          agentic-secrets redact "OPENAI_API_KEY=..."
        """)
    }

    private static func handleAdapter(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError.missingArgument("adapter subcommand")
        }
        switch subcommand {
        case "list":
            print(try AgenticSecretsJSON.encodePretty(PolicyPackRegistryDocument(entries: [])))
        case "install-payload":
            guard args.count >= 3 else { throw CLIError.missingArgument("payload.json registry.json") }
            let payload = try JSONDecoder().decode(CommandPolicyPackPayload.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            try PolicyPackRegistryStore(url: URL(fileURLWithPath: args[2])).install(payload: payload)
            print("installed \(payload.policyPackID)@\(payload.policyPackVersion)")
        case "revoke":
            guard args.count >= 3 else { throw CLIError.missingArgument("adapter-id registry.json") }
            try PolicyPackRegistryStore(url: URL(fileURLWithPath: args[2])).revoke(policyPackID: args[1])
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
            if passthrough.contains("--secret-prompt") {
                guard let secretIndex = passthrough.firstIndex(of: "--secret-prompt") else {
                    throw CLIError.missingArgument("--secret-prompt")
                }
                passthrough.remove(at: secretIndex)
                passthrough.append("--secret-stdin")
                let environmentNames = values(after: "--env", in: passthrough)
                guard environmentNames.count == 1, let environmentName = environmentNames.first else {
                    throw CLIError.missingArgument("--secret-prompt requires exactly one --env")
                }
                let material = try readSecretFromPrompt(label: "\(name) \(environmentName)")
                try material.withData { data in
                    try runCoreCommand(["register-cli", "--name", name] + passthrough, standardInput: data)
                }
            } else {
                try runCoreCommand(["register-cli", "--name", name] + passthrough)
            }
        case "unregister":
            guard args.count >= 2 else { throw CLIError.missingArgument("cli name") }
            let name = args[1]
            var passthrough = Array(args.dropFirst(2))
            if !passthrough.contains("--state-dir") {
                passthrough += ["--state-dir", defaultStateDirectory().path]
            }
            try runCoreCommand(["unregister-cli", "--name", name] + passthrough)
        case "trust-refresh":
            guard args.count >= 2 else { throw CLIError.missingArgument("cli name") }
            let name = args[1]
            var passthrough = Array(args.dropFirst(2))
            if !passthrough.contains("--state-dir") {
                passthrough += ["--state-dir", defaultStateDirectory().path]
            }
            try runCoreCommand(["trust-refresh-cli", "--name", name] + passthrough)
        case "run":
            guard args.count >= 2 else { throw CLIError.missingArgument("cli name") }
            let name = args[1]
            var passthrough = Array(args.dropFirst(2))
            guard passthrough.contains("--") else {
                throw CLIError.missingArgument("-- before target arguments")
            }
            let separator = passthrough.firstIndex(of: "--")!
            if !passthrough[..<separator].contains("--state-dir") {
                passthrough.insert(contentsOf: ["--state-dir", defaultStateDirectory().path], at: 0)
            }
            try runCoreCommand(["run-cli", "--name", name] + passthrough)
        case "shim":
            try handleCLIShim(Array(args.dropFirst()))
        default:
            throw CLIError.missingArgument("known cli subcommand")
        }
    }

    private static func handleCLIShim(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError.missingArgument("cli shim subcommand")
        }
        switch subcommand {
        case "install":
            try installCLIShim(Array(args.dropFirst()))
        case "uninstall":
            try uninstallCLIShim(Array(args.dropFirst()))
        case "path":
            print(defaultShimDirectory().path)
        default:
            throw CLIError.missingArgument("known cli shim subcommand")
        }
    }

    private static func installCLIShim(_ args: [String]) throws {
        guard let name = args.first, !name.hasPrefix("-") else {
            throw CLIError.missingArgument("cli name")
        }
        try validateCLIShimName(name)
        var options = Array(args.dropFirst())
        let configureShell = options.removeAllOccurrences(of: "--configure-shell")
        let force = options.removeAllOccurrences(of: "--force")
        let shimDir = try optionalValue(after: "--shim-dir", removingFrom: &options)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultShimDirectory()
        _ = try optionalValue(after: "--state-dir", removingFrom: &options)
        guard options.isEmpty else {
            throw CLIError.unknownCommand(options.joined(separator: " "))
        }

        let shimBinary = URL(fileURLWithPath: try shimBinaryPath())
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimDir.path)
        let shimURL = shimDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: shimURL.path) || CommandShimInstallationInspector.isSymlink(shimURL) {
            if force {
                switch CommandShimInstallationInspector.replacementSafety(for: shimURL) {
                case .replaceable:
                    try FileManager.default.removeItem(at: shimURL)
                case .directory:
                    throw CLIError.pathExists("refusing to replace directory at shim path: \(shimURL.path)")
                case .absent:
                    break
                }
            } else if !CommandShimInstallationInspector.pointsToShimBinary(shimURL: shimURL, expectedShimBinary: shimBinary) {
                throw CLIError.pathExists("shim path already exists: \(shimURL.path). Re-run with --force only if this should be replaced.")
            } else {
                printCLIShimInstallResult(name: name, shimURL: shimURL, shimDir: shimDir, configureShell: configureShell, alreadyInstalled: true)
                if configureShell {
                    try configureShellPath(directory: shimDir, label: "AgenticSecrets CLI shims")
                }
                return
            }
        }
        try FileManager.default.createSymbolicLink(atPath: shimURL.path, withDestinationPath: shimBinary.path)
        if configureShell {
            try configureShellPath(directory: shimDir, label: "AgenticSecrets CLI shims")
        }
        printCLIShimInstallResult(name: name, shimURL: shimURL, shimDir: shimDir, configureShell: configureShell, alreadyInstalled: false)
    }

    private static func uninstallCLIShim(_ args: [String]) throws {
        guard let name = args.first, !name.hasPrefix("-") else {
            throw CLIError.missingArgument("cli name")
        }
        try validateCLIShimName(name)
        var options = Array(args.dropFirst())
        let shimDir = try optionalValue(after: "--shim-dir", removingFrom: &options)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultShimDirectory()
        guard options.isEmpty else {
            throw CLIError.unknownCommand(options.joined(separator: " "))
        }
        let shimURL = shimDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: shimURL.path) || CommandShimInstallationInspector.isSymlink(shimURL) else {
            print("AgenticSecrets shim for \(name) is not installed at \(shimURL.path).")
            return
        }
        guard CommandShimInstallationInspector.pointsToShimBinary(
            shimURL: shimURL,
            expectedShimBinary: URL(fileURLWithPath: try shimBinaryPath())
        ) else {
            throw CLIError.pathExists("refusing to remove non-AgenticSecrets path: \(shimURL.path)")
        }
        try FileManager.default.removeItem(at: shimURL)
        print("AgenticSecrets shim removed for \(name): \(shimURL.path)")
    }

    private static func printCLIShimInstallResult(
        name: String,
        shimURL: URL,
        shimDir: URL,
        configureShell: Bool,
        alreadyInstalled: Bool
    ) {
        print("""
        AgenticSecrets shim \(alreadyInstalled ? "already installed" : "installed") for \(name).

        Shim:
          \(shimURL.path)

        Normal commands now go through AgenticSecrets secret delivery when this shim directory is before the native CLI on PATH.
        If \(name) is not registered yet, the first non-help command will fail closed with a registration error.
        Global help/version commands pass through without secret delivery:
          \(name) --help
          \(name) version
        """)
        if configureShell {
            print("Shell PATH configured for future sessions.")
        } else {
            print("""

            For the current shell:
              export PATH="\(shimDir.path):$PATH"

            For future sessions:
              agentic-secrets cli shim install \(name) --configure-shell
            """)
        }
    }

    private static func runCoreCommand(_ arguments: [String], standardInput: Data? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try coreDaemonPath())
        process.arguments = arguments
        let inputPipe: Pipe?
        if let standardInput {
            let pipe = Pipe()
            inputPipe = pipe
            process.standardInput = pipe
            pipe.fileHandleForWriting.write(standardInput)
            pipe.fileHandleForWriting.write(Data([10]))
            pipe.fileHandleForWriting.closeFile()
        } else {
            inputPipe = nil
            process.standardInput = FileHandle.standardInput
        }
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        _ = inputPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            exit(process.terminationStatus)
        }
    }

    private static func coreDaemonPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_SECRETS_CORE_BINARY"], !override.isEmpty {
            return override
        }
        let candidates = executableCandidateURLs().map {
            $0.deletingLastPathComponent().appendingPathComponent("agentic-secrets-brokerd")
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        throw CLIError.missingArgument("agentic-secrets-brokerd sibling binary or AGENTIC_SECRETS_CORE_BINARY")
    }

    private static func shimBinaryPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_SECRETS_SHIM_BINARY"], !override.isEmpty {
            return override
        }
        let candidates = executableCandidateURLs().map {
            $0.deletingLastPathComponent().appendingPathComponent("agentic-secrets-shim")
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        throw CLIError.missingArgument("agentic-secrets-shim sibling binary or AGENTIC_SECRETS_SHIM_BINARY")
    }

    private static func defaultStateDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_SECRETS_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return defaultInstallPrefix().map {
            $0.appendingPathComponent("var/agentic-secrets", isDirectory: true)
        } ?? LocalInstallLayout.defaultStateDirectory()
    }

    private static func defaultShimDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_SECRETS_SHIM_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return defaultInstallPrefix().map {
            $0.appendingPathComponent("shims", isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgenticSecrets/LocalInstall/shims", isDirectory: true)
    }

    private static func defaultInstallPrefix() -> URL? {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_SECRETS_INSTALL_PREFIX"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        for executable in executableCandidateURLs() {
            let directory = executable.deletingLastPathComponent()
            if directory.lastPathComponent == "bin",
               FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("agentic-secrets-shim").path) {
                return directory.deletingLastPathComponent()
            }
        }
        for invoked in executableCandidateURLs().map({ $0.resolvingSymlinksInPath() }) {
            if isUserApplicationsExecutable(invoked) {
                return defaultLocalInstallPrefix()
            }
            let components = invoked.pathComponents
            if let applicationsIndex = components.lastIndex(of: "Applications"), applicationsIndex > 0 {
                let prefix = URL(fileURLWithPath: "/" + components[1..<applicationsIndex].joined(separator: "/"), isDirectory: true)
                if isLegacyLocalInstallPrefix(prefix) || (prefix.path != "/" && components.indices.contains(applicationsIndex + 1) && components[applicationsIndex + 1] == "AgenticSecrets.app") {
                    return prefix
                }
            }
        }
        return nil
    }

    private static func defaultLocalInstallPrefix() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgenticSecrets/LocalInstall", isDirectory: true)
    }

    private static func userApplicationsApp() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/AgenticSecrets.app", isDirectory: true)
    }

    private static func isUserApplicationsExecutable(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(userApplicationsApp().standardizedFileURL.path + "/Contents/MacOS/")
    }

    private static func isLegacyLocalInstallPrefix(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasSuffix("/Library/Application Support/AgenticSecrets/LocalInstall")
    }

    private static func executableCandidateURLs() -> [URL] {
        var candidates: [URL] = []
        if let bundleExecutable = Bundle.main.executableURL {
            candidates.append(bundleExecutable)
        }
        let argv0 = CommandLine.arguments[0]
        if argv0.contains("/") {
            candidates.append(URL(fileURLWithPath: argv0))
        } else if let pathExecutable = findExecutableOnPATH(argv0) {
            candidates.append(URL(fileURLWithPath: pathExecutable))
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }

    private static func readSecretFromPrompt(label: String) throws -> SecretMaterial {
        guard isatty(STDIN_FILENO) == 1 else {
            throw CLIError.missingArgument("--secret-prompt requires a TTY")
        }
        fputs("Enter secret for \(label): ", stderr)
        var oldTermios = termios()
        guard tcgetattr(STDIN_FILENO, &oldTermios) == 0 else {
            throw CLIError.missingArgument("failed to read terminal settings")
        }
        var newTermios = oldTermios
        newTermios.c_lflag &= ~UInt(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &newTermios) == 0 else {
            throw CLIError.missingArgument("failed to disable terminal echo")
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &oldTermios)
            fputs("\n", stderr)
        }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw CLIError.missingArgument("empty secret")
        }
        return SecretMaterial(utf8: line)
    }

    private static func values(after option: String, in args: [String]) -> [String] {
        args.indices.compactMap { index in
            guard args[index] == option, args.indices.contains(index + 1) else {
                return nil
            }
            return args[index + 1]
        }
    }

    private static func optionalValue(after option: String, removingFrom args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: option) else {
            return nil
        }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else {
            throw CLIError.missingArgument(option)
        }
        let value = args[valueIndex]
        args.removeSubrange(index...valueIndex)
        return value
    }

    private static func defaultShellConfig() -> URL {
        let shell = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "zsh").lastPathComponent
        switch shell {
        case "bash":
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bashrc")
        case "zsh":
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        default:
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".profile")
        }
    }

    private static func configureShellPath(directory: URL, label: String) throws {
        let target = defaultShellConfig()
        let quotedDirectory = try shellSingleQuotedPath(directory.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        let block = """

        # \(label)
        agentic_secrets_path_dir=\(quotedDirectory)
        case ":$PATH:" in
          *":$agentic_secrets_path_dir:"*) ;;
          *) export PATH="$agentic_secrets_path_dir:$PATH" ;;
        esac
        """
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(block.utf8))
        try handle.write(contentsOf: Data([10]))
        print("Configured shell PATH in \(target.path)")
    }

    private static func shellSingleQuotedPath(_ path: String) throws -> String {
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CLIError.pathExists("refusing to write shell PATH block for a path containing control characters")
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validateCLIShimName(_ name: String) throws {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !name.contains("/") else {
            throw CLIError.missingArgument("valid cli name")
        }
    }

    private static func resolveExecutable(_ name: String) throws -> String {
        guard !name.contains("/") else {
            guard FileManager.default.isExecutableFile(atPath: name) else {
                throw CLIError.missingArgument("executable target for \(name)")
            }
            return name
        }
        guard let output = findExecutableOnPATH(name) else {
            throw CLIError.executableNotFound(name)
        }
        return output
    }

    private static func findExecutableOnPATH(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return nil
        }
        return output
    }

}

enum CLIError: Error, CustomStringConvertible {
    case missingArgument(String)
    case unknownCommand(String)
    case executableNotFound(String)
    case pathExists(String)

    var description: String {
        switch self {
        case .missingArgument(let argument):
            "Missing required argument: \(argument)"
        case .unknownCommand(let command):
            "Unknown command: \(command)"
        case .executableNotFound(let name):
            "Could not find executable '\(name)' on PATH. Install it or pass --target /absolute/path/to/\(name)."
        case .pathExists(let message):
            message
        }
    }
}

private extension Array where Element == String {
    mutating func removeAllOccurrences(of value: String) -> Bool {
        let originalCount = count
        removeAll { $0 == value }
        return count != originalCount
    }
}
