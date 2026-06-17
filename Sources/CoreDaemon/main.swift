import AgenticFortressCore
import Foundation

@main
struct AgenticFortressCoreDaemon {
    static func main() throws {
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
}

enum CoreDaemonError: Error, CustomStringConvertible {
    case missingArgument(String)
    case unknownCommand(String)

    var description: String {
        switch self {
        case .missingArgument(let argument):
            "Missing argument: \(argument)"
        case .unknownCommand(let command):
            "Unknown core daemon command: \(command)"
        }
    }
}
