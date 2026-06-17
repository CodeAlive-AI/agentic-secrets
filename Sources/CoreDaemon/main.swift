import AgenticFortressCore
import Darwin
import Foundation

@main
struct AgenticFortressCoreDaemon {
    static func main() {
        do {
            try run()
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(64)
        }
    }

    private static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        if let command = args.first {
            args.removeFirst()
            switch command {
            case "serve":
                try serve(args)
            case "serve-once":
                try serveOnce(args)
                return
            case "local-secret-smoke":
                try runLocalSecretSmoke(args)
                return
            case "register-cli":
                try registerCLI(args)
                return
            case "unregister-cli":
                try unregisterCLI(args)
                return
            default:
                throw CoreDaemonError.unknownCommand(command)
            }
        }

        let report = ReleaseGateRunner().staticReport()
        print(try AgenticFortressJSON.encodePretty([
            "service": "agentic-fortressd-core",
            "mode": "local-self-build",
            "can_run_local": String(report.canRunLocal),
            "can_distribute_binary": String(report.canDistributeBinary),
            "note": "Default production track is self-build with local ad-hoc signing; Developer ID distribution is optional future maintainer work."
        ]))
    }

    private static func registerCLI(_ args: [String]) throws {
        let name = try requiredValue(after: "--name", in: args)
        let target = try requiredValue(after: "--target", in: args)
        let environmentNames = values(after: "--env", in: args)
        let layout = AgenticFortressStateLayout(stateDirectory: stateDirectory(from: args))
        let values: [String: SecretMaterial]
        if args.contains("--secrets-json-stdin") {
            values = try readSecretJSONFromStdin(allowedEnvironmentNames: environmentNames)
        } else if args.contains("--secret-stdin") {
            guard environmentNames.count == 1, let environmentName = environmentNames.first else {
                throw CoreDaemonError.invalidArguments("--secret-stdin requires exactly one --env")
            }
            values = [environmentName: try readSingleSecretFromStdin()]
        } else if args.contains("--secret-prompt") {
            guard environmentNames.count == 1, let environmentName = environmentNames.first else {
                throw CoreDaemonError.invalidArguments("--secret-prompt requires exactly one --env")
            }
            values = [environmentName: try readSingleSecretFromPrompt(label: "\(name) \(environmentName)")]
        } else {
            throw CoreDaemonError.invalidArguments("use --secret-stdin, --secrets-json-stdin, or --secret-prompt")
        }
        let registration = try layout.registrationService.register(name: name, targetPath: target, environmentValues: values)
        print(try AgenticFortressJSON.encodePretty(CLIRegistrationCommandResponse(
            status: "registered",
            name: registration.name,
            targetPath: registration.targetPath,
            environments: registration.environmentBindings.map(\.environmentName),
            registry: layout.registryURL.path,
            secretStore: "local-encrypted-file",
            nextStep: "Registration stored. Do not create a native CLI context containing this token."
        )))
    }

    private static func unregisterCLI(_ args: [String]) throws {
        let name = try requiredValue(after: "--name", in: args)
        let deleteSecrets = args.contains("--delete-secrets")
        let layout = AgenticFortressStateLayout(stateDirectory: stateDirectory(from: args))
        let registration = try layout.registrationService.unregister(name: name, deleteSecrets: deleteSecrets)
        print(try AgenticFortressJSON.encodePretty(CLIUnregistrationCommandResponse(
            status: "unregistered",
            name: registration.name,
            deletedSecrets: deleteSecrets,
            environments: registration.environmentBindings.map(\.environmentName)
        )))
    }

    private static func serveOnce(_ args: [String]) throws {
        let socket = try requiredValue(after: "--socket", in: args)
        let manifestPath = try requiredValue(after: "--manifest", in: args)
        let manifest = try InstallManifestStore.load(path: manifestPath)
        let handler = CoreIPCHandler(authorizer: CoreIPCAuthorizer(installManifest: manifest))
        try UnixDomainSocketIPCServer(socketPath: socket, handler: handler).serveOnce()
    }

    private static func serve(_ args: [String]) throws -> Never {
        while true {
            try serveOnce(args)
        }
    }

    private static func runLocalSecretSmoke(_ args: [String]) throws {
        let service = value(after: "--service", in: args) ?? "com.agenticfortress.interactive-smoke"
        let alias = SecretAlias(value(after: "--alias", in: args) ?? "agentic-fortress.interactive-smoke")
        let smokeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(service)-\(UUID().uuidString)", isDirectory: true)
        let store = LocalEncryptedSecretStore(
            storeURL: smokeRoot.appendingPathComponent("secrets.json"),
            keyURL: smokeRoot.appendingPathComponent("secret-store.key")
        )
        let material = SecretMaterial(utf8: "generated-\(UUID().uuidString)")
        try store.store(alias: alias, material: material, label: "AgenticFortress interactive smoke")
        defer { try? FileManager.default.removeItem(at: smokeRoot) }

        let command = CommandClassifier().classify(executableName: "agentic-fortressd-core", arguments: ["local-secret-smoke"])
        let target = TargetAssessor().synthetic(path: CommandLine.arguments.first ?? "agentic-fortressd-core", identity: "sha256:local-secret-smoke")
        let manifest = DecisionManifestFactory().make(
            command: command,
            intent: DeliveryIntent(
                flow: .cliEnv,
                secretAlias: alias.rawValue,
                delivery: .env,
                environmentName: "AGENTIC_FORTRESS_SMOKE_SECRET",
                workspace: FileManager.default.currentDirectoryPath,
                parentApp: ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "unknown"
            ),
            target: target
        )
        let session = ApprovalSessionStore().create(manifest: manifest, policyEpoch: 1, ttl: 30)
        _ = try store.resolve(alias: alias, approvedFor: session)
        print(try AgenticFortressJSON.encodePretty([
            "status": "ok",
            "secret": "resolved-redacted",
            "store": "local-encrypted-file",
            "manifestDigest": manifest.digest,
            "promptReasonContainsTarget": String(session.authenticationReason.contains(manifest.target.display)),
            "promptReasonContainsWorkspace": String(session.authenticationReason.contains(manifest.workspace.display)),
            "promptReasonContainsDelivery": String(session.authenticationReason.contains(manifest.secret.delivery.rawValue))
        ]))
    }

    private static func requiredValue(after flag: String, in args: [String]) throws -> String {
        guard let value = value(after: flag, in: args) else {
            throw CoreDaemonError.missingArgument(flag)
        }
        return value
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else { return nil }
        return args[valueIndex]
    }

    private static func values(after flag: String, in args: [String]) -> [String] {
        args.indices.compactMap { index in
            guard args[index] == flag else { return nil }
            let valueIndex = args.index(after: index)
            guard valueIndex < args.endIndex else { return nil }
            return args[valueIndex]
        }
    }

    private static func stateDirectory(from args: [String]) -> URL {
        if let stateDir = value(after: "--state-dir", in: args) {
            return URL(fileURLWithPath: stateDir, isDirectory: true)
        }
        return AgenticFortressStateLayout.defaultStateDirectory()
    }

    private static func readSingleSecretFromStdin() throws -> SecretMaterial {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let trimmed = trimTrailingNewlines(data)
        guard !trimmed.isEmpty else {
            throw CoreDaemonError.invalidArguments("empty secret stdin")
        }
        return SecretMaterial(bytes: trimmed)
    }

    private static func readSecretJSONFromStdin(allowedEnvironmentNames: [String]) throws -> [String: SecretMaterial] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        let allowed = Set(allowedEnvironmentNames)
        guard !raw.isEmpty else {
            throw CoreDaemonError.invalidArguments("empty secrets JSON")
        }
        if !allowed.isEmpty && !Set(raw.keys).isSubset(of: allowed) {
            throw CoreDaemonError.invalidArguments("secrets JSON contains env names not listed with --env")
        }
        return raw.mapValues { SecretMaterial(utf8: $0) }
    }

    private static func readSingleSecretFromPrompt(label: String) throws -> SecretMaterial {
        guard isatty(STDIN_FILENO) == 1 else {
            throw CoreDaemonError.invalidArguments("--secret-prompt requires a TTY")
        }
        fputs("Enter secret for \(label): ", stderr)
        var oldTermios = termios()
        guard tcgetattr(STDIN_FILENO, &oldTermios) == 0 else {
            throw CoreDaemonError.invalidArguments("failed to read terminal settings")
        }
        var newTermios = oldTermios
        newTermios.c_lflag &= ~UInt(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &newTermios) == 0 else {
            throw CoreDaemonError.invalidArguments("failed to disable terminal echo")
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &oldTermios)
            fputs("\n", stderr)
        }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw CoreDaemonError.invalidArguments("empty secret")
        }
        return SecretMaterial(utf8: line)
    }

    private static func trimTrailingNewlines(_ data: Data) -> Data {
        var bytes = Array(data)
        while let last = bytes.last, last == 10 || last == 13 {
            bytes.removeLast()
        }
        return Data(bytes)
    }
}

enum CoreDaemonError: Error, CustomStringConvertible {
    case missingArgument(String)
    case unknownCommand(String)
    case invalidArguments(String)

    var description: String {
        switch self {
        case .missingArgument(let argument):
            "Missing argument: \(argument)"
        case .unknownCommand(let command):
            "Unknown core daemon command: \(command)"
        case .invalidArguments(let reason):
            "Invalid arguments: \(reason)"
        }
    }
}

private struct CLIRegistrationCommandResponse: Codable {
    var status: String
    var name: String
    var targetPath: String
    var environments: [String]
    var registry: String
    var secretStore: String
    var nextStep: String
}

private struct CLIUnregistrationCommandResponse: Codable {
    var status: String
    var name: String
    var deletedSecrets: Bool
    var environments: [String]
}
