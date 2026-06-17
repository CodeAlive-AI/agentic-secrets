import AgenticFortressCore
import Foundation

@main
struct AgenticFortressShim {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--ipc-health" {
            try runIPCHealth(Array(args.dropFirst()))
            return
        }

        let invokedName = URL(fileURLWithPath: CommandLine.arguments.first ?? "agentic-fortress-shim").lastPathComponent
        let command = CommandClassifier().classify(executableName: invokedName, arguments: args)
        let target = TargetAssessor().synthetic(path: "/usr/bin/env", identity: "sha256:shim-demo")
        let intent = DeliveryIntent(
            flow: .cliEnv,
            secretAlias: "cloud.hcloud.dev",
            delivery: .env,
            environmentName: "HCLOUD_TOKEN",
            workspace: FileManager.default.currentDirectoryPath,
            parentApp: ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "unknown"
        )
        let manifest = DecisionManifestFactory().make(command: command, intent: intent, target: target)
        let state = PolicyState()
        let decision = try PolicyEngine().authorize(command: command, intent: intent, target: target, approval: manifest.approvalOptions.contains(.once) ? .once : .deny, state: state)
        let redactedManifest = try AgenticFortressJSON.encodePretty(manifest)

        switch decision {
        case .allowOnce:
            print(redactedManifest)
            print("AgenticFortress shim dry-run: approval required from core before exec. No secret was read or injected by this standalone binary.")
        case .allowRemembered:
            print(redactedManifest)
            print("AgenticFortress shim dry-run: remembered leases are issued by core, not by direct shim execution.")
        case .deny(let reason):
            print(redactedManifest)
            print("Denied: \(reason)")
        }
    }

    private static func runIPCHealth(_ args: [String]) throws {
        let socket = try requiredValue(after: "--socket", in: args)
        _ = try requiredValue(after: "--manifest", in: args)
        let version = value(after: "--version", in: args) ?? "0.1.0"
        let path = CommandLine.arguments.first ?? "agentic-fortress-shim"
        let peer = try SelfBuildPeerValidator.identity(helperName: "agentic-fortress-shim", path: path, version: version)
        let request = CoreIPCRequest(requestID: "req_" + shortDigest(UUID().uuidString, length: 12), operation: .health, peer: peer)
        let response = try UnixDomainSocketIPCClient(socketPath: socket).send(request)
        print(try AgenticFortressJSON.encodePretty(response))
    }

    private static func requiredValue(after flag: String, in args: [String]) throws -> String {
        guard let value = value(after: flag, in: args) else {
            throw ShimCLIError.missingArgument(flag)
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

enum ShimCLIError: Error, CustomStringConvertible {
    case missingArgument(String)

    var description: String {
        switch self {
        case .missingArgument(let argument):
            "Missing argument: \(argument)"
        }
    }
}
