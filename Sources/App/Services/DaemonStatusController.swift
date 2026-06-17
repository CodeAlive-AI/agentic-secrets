import AgenticFortressCore
import Foundation

enum DaemonRunState: String, Codable, Equatable, Sendable {
    case unknown
    case healthy
    case unavailable
    case repairing
}

struct DaemonStatus: Codable, Equatable, Sendable {
    var state: DaemonRunState
    var socketPath: String
    var launchAgentPath: String?
    var message: String
    var recoveryCommand: String?
    var checkedAt: Date

    var canRepair: Bool {
        launchAgentPath != nil
    }
}

protocol DaemonStatusControlling: Sendable {
    func status() async -> DaemonStatus
    func repair() async -> DaemonStatus
}

struct LocalDaemonStatusController: DaemonStatusControlling {
    var client: any AgenticFortressClient

    init(client: any AgenticFortressClient) {
        self.client = client
    }

    func status() async -> DaemonStatus {
        let paths = daemonPaths()
        do {
            try await client.health()
            return DaemonStatus(
                state: .healthy,
                socketPath: paths.socketPath,
                launchAgentPath: paths.launchAgentPath,
                message: "Core daemon is reachable.",
                recoveryCommand: nil,
                checkedAt: Date()
            )
        } catch {
            return unavailableStatus(paths: paths, message: "Core daemon is not reachable: \(error)")
        }
    }

    func repair() async -> DaemonStatus {
        let paths = daemonPaths()
        guard let launchAgentPath = paths.launchAgentPath else {
            return unavailableStatus(paths: paths, message: "No local LaunchAgent was found for this app bundle.")
        }
        guard FileManager.default.fileExists(atPath: launchAgentPath) else {
            return unavailableStatus(paths: paths, message: "LaunchAgent plist is missing at \(launchAgentPath).")
        }

        let service = "gui/\(getuid())/com.agenticfortress.core"
        _ = runLaunchctl(["kickstart", "-k", service])
        try? await Task.sleep(for: .milliseconds(350))
        if (await status()).state == .healthy {
            return await status()
        }

        _ = runLaunchctl(["bootout", "gui/\(getuid())", launchAgentPath])
        let bootstrap = runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentPath])
        guard bootstrap.exitCode == 0 else {
            return unavailableStatus(paths: paths, message: "launchctl bootstrap failed: \(bootstrap.output)")
        }
        try? await Task.sleep(for: .milliseconds(500))
        return await status()
    }

    private func daemonPaths() -> (socketPath: String, launchAgentPath: String?, recoveryCommand: String) {
        let defaults = IPCAgenticFortressClient.defaultPaths()
        if let prefix = IPCAgenticFortressClient.installPrefixFromBundle() {
            let launchAgent = prefix
                .appendingPathComponent("Library/LaunchAgents/com.agenticfortress.core.plist")
                .path
            return (
                defaults.socketPath,
                launchAgent,
                "scripts/install_local.sh --load"
            )
        }
        return (
            defaults.socketPath,
            nil,
            "scripts/install_local.sh --load"
        )
    }

    private func unavailableStatus(paths: (socketPath: String, launchAgentPath: String?, recoveryCommand: String), message: String) -> DaemonStatus {
        DaemonStatus(
            state: .unavailable,
            socketPath: paths.socketPath,
            launchAgentPath: paths.launchAgentPath,
            message: message,
            recoveryCommand: paths.recoveryCommand,
            checkedAt: Date()
        )
    }

    private func runLaunchctl(_ arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (127, String(describing: error))
        }
    }
}

struct StubDaemonStatusController: DaemonStatusControlling {
    var statusValue: DaemonStatus
    var repairValue: DaemonStatus?

    func status() async -> DaemonStatus {
        statusValue
    }

    func repair() async -> DaemonStatus {
        repairValue ?? statusValue
    }
}
