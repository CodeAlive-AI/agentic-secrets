import AgenticFortressCore
import Foundation

@main
struct AgenticFortressShim {
    static func main() throws {
        let invokedName = URL(fileURLWithPath: CommandLine.arguments.first ?? "agentic-fortress-shim").lastPathComponent
        let args = Array(CommandLine.arguments.dropFirst())
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
}

