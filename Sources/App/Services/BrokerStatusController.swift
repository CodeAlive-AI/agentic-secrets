import AgenticSecretsBroker
import Foundation

enum BrokerRunState: String, Codable, Equatable, Sendable {
    case unknown
    case healthy
    case unavailable
    case repairing
    case installing
}

struct BrokerStatus: Codable, Equatable, Sendable {
    var state: BrokerRunState
    var socketPath: String
    var launchAgentPath: String?
    var message: String
    var detail: String?
    var recoveryCommand: String?
    var checkedAt: Date

    var canRepair: Bool {
        launchAgentPath != nil
    }
}

struct BrokerInstallPlan: Codable, Equatable, Sendable {
    var supported: Bool
    var title: String
    var summary: String
    var prefixPath: String
    var appSourcePath: String
    var appDestinationPath: String
    var binDirectoryPath: String
    var stateDirectoryPath: String
    var runDirectoryPath: String
    var launchAgentPath: String
    var manifestPath: String
    var socketPath: String
    var commandPreview: String
    var missingExecutables: [String]
    var currentAppIsInstalledCopy: Bool

    var canInstall: Bool {
        supported && missingExecutables.isEmpty
    }

    var primaryActionTitle: String {
        FileManager.default.fileExists(atPath: launchAgentPath) ? "Repair Local Daemon" : "Install Local Daemon"
    }
}

protocol BrokerStatusControlling: Sendable {
    func status() async -> BrokerStatus
    func repair() async -> BrokerStatus
    func installPlan() async -> BrokerInstallPlan
    func installOrRepair() async -> BrokerStatus
}

struct LocalBrokerStatusController: BrokerStatusControlling {
    var client: any ControlPlaneClient

    init(client: any ControlPlaneClient) {
        self.client = client
    }

    func status() async -> BrokerStatus {
        let paths = daemonPaths()
        do {
            try await client.health()
            return BrokerStatus(
                state: .healthy,
                socketPath: paths.socketPath,
                launchAgentPath: paths.launchAgentPath,
                message: "Broker daemon is reachable.",
                detail: nil,
                recoveryCommand: nil,
                checkedAt: Date()
            )
        } catch {
            return unavailableStatus(paths: paths, reason: daemonUnavailableReason(error), detail: String(describing: error))
        }
    }

    func repair() async -> BrokerStatus {
        let paths = daemonPaths()
        guard let launchAgentPath = paths.launchAgentPath else {
            return unavailableStatus(paths: paths, message: "No local LaunchAgent was found for this app bundle.")
        }
        guard FileManager.default.fileExists(atPath: launchAgentPath) else {
            return unavailableStatus(paths: paths, message: "LaunchAgent plist is missing at \(launchAgentPath).")
        }

        let service = "gui/\(getuid())/com.agenticsecrets.broker"
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

    func installPlan() async -> BrokerInstallPlan {
        makeInstallPlan()
    }

    func installOrRepair() async -> BrokerStatus {
        let plan = makeInstallPlan()
        guard plan.canInstall else {
            return BrokerStatus(
                state: .unavailable,
                socketPath: plan.socketPath,
                launchAgentPath: plan.launchAgentPath,
                message: plan.summary,
                detail: plan.missingExecutables.isEmpty ? nil : "Missing helpers: \(plan.missingExecutables.joined(separator: ", "))",
                recoveryCommand: plan.commandPreview,
                checkedAt: Date()
            )
        }

        do {
            try install(plan: plan)
            try? await Task.sleep(for: .milliseconds(500))
            let checked = await status()
            if checked.state == .healthy || plan.currentAppIsInstalledCopy {
                return checked
            }
            return BrokerStatus(
                state: .unavailable,
                socketPath: plan.socketPath,
                launchAgentPath: plan.launchAgentPath,
                message: "Local daemon was installed. Open the installed copy so the authenticated IPC manifest matches the running UI.",
                detail: nil,
                recoveryCommand: nil,
                checkedAt: Date()
            )
        } catch {
            return BrokerStatus(
                state: .unavailable,
                socketPath: plan.socketPath,
                launchAgentPath: plan.launchAgentPath,
                message: "Install failed. Review Diagnostics and try again.",
                detail: String(describing: error),
                recoveryCommand: plan.commandPreview,
                checkedAt: Date()
            )
        }
    }

    private func daemonPaths() -> (socketPath: String, launchAgentPath: String?, recoveryCommand: String) {
        let defaults = IPCControlPlaneClient.defaultPaths()
        if let prefix = IPCControlPlaneClient.installPrefixFromBundle() {
            let launchAgent = prefix
                .appendingPathComponent("Library/LaunchAgents/com.agenticsecrets.broker.plist")
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

    private func makeInstallPlan() -> BrokerInstallPlan {
        let source = Bundle.main.bundleURL.standardizedFileURL
        let prefix = IPCControlPlaneClient.installPrefixFromBundle() ?? Self.defaultInstallPrefix()
        let appDestination = prefix.appendingPathComponent("Applications/AgenticSecrets.app")
        let binDirectory = prefix.appendingPathComponent("bin", isDirectory: true)
        let stateDirectory = prefix.appendingPathComponent("var/agentic-secrets", isDirectory: true)
        let runDirectory = prefix.appendingPathComponent("run/agentic-secrets", isDirectory: true)
        let launchAgent = prefix.appendingPathComponent("Library/LaunchAgents/com.agenticsecrets.broker.plist")
        let manifest = stateDirectory.appendingPathComponent("install-manifest.json")
        let socket = URL(fileURLWithPath: IPCControlPlaneClient.defaultRuntimeSocketPath())
        let sourceMacOS = source.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let missing = Self.installExecutables.filter {
            !FileManager.default.isExecutableFile(atPath: sourceMacOS.appendingPathComponent($0).path)
        }
        let isAppBundle = source.pathExtension == "app"
        let currentInstalled = source.path == appDestination.standardizedFileURL.path
        let supported = isAppBundle && missing.isEmpty
        let summary: String
        if !isAppBundle {
            summary = "This running process is not a packaged .app bundle. Use the CLI installer from a source checkout."
        } else if !missing.isEmpty {
            summary = "This app bundle is missing helper executables: \(missing.joined(separator: ", ")). Build a release package before installing."
        } else if currentInstalled {
            summary = "Repair will refresh helper links, the install manifest, and the per-user LaunchAgent."
        } else {
            summary = "Install will copy this app bundle into the local self-build install prefix and start the broker daemon."
        }
        return BrokerInstallPlan(
            supported: supported,
            title: currentInstalled ? "Repair Local Install" : "Install Local Daemon",
            summary: summary,
            prefixPath: prefix.path,
            appSourcePath: source.path,
            appDestinationPath: appDestination.path,
            binDirectoryPath: binDirectory.path,
            stateDirectoryPath: stateDirectory.path,
            runDirectoryPath: runDirectory.path,
            launchAgentPath: launchAgent.path,
            manifestPath: manifest.path,
            socketPath: socket.path,
            commandPreview: "scripts/install_local.sh --load",
            missingExecutables: missing,
            currentAppIsInstalledCopy: currentInstalled
        )
    }

    private func install(plan: BrokerInstallPlan) throws {
        let fileManager = FileManager.default
        let appDestination = URL(fileURLWithPath: plan.appDestinationPath, isDirectory: true)
        let binDirectory = URL(fileURLWithPath: plan.binDirectoryPath, isDirectory: true)
        let stateDirectory = URL(fileURLWithPath: plan.stateDirectoryPath, isDirectory: true)
        let runDirectory = URL(fileURLWithPath: plan.runDirectoryPath, isDirectory: true)
        let socketDirectory = URL(fileURLWithPath: plan.socketPath).deletingLastPathComponent()
        let launchAgent = URL(fileURLWithPath: plan.launchAgentPath)
        let manifest = URL(fileURLWithPath: plan.manifestPath)
        let source = URL(fileURLWithPath: plan.appSourcePath, isDirectory: true)

        try fileManager.createDirectory(at: appDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory.path)

        if !plan.currentAppIsInstalledCopy {
            try? fileManager.removeItem(at: appDestination)
            let copied = runProcess(executable: "/usr/bin/ditto", arguments: [source.path, appDestination.path])
            guard copied.exitCode == 0 else {
                throw DaemonInstallError.commandFailed("ditto", copied.output)
            }
        }

        for executable in Self.installExecutables {
            let link = binDirectory.appendingPathComponent(executable)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(
                at: link,
                withDestinationURL: appDestination.appendingPathComponent("Contents/MacOS/\(executable)")
            )
        }

        try launchAgentPlist(plan: plan).write(to: launchAgent, atomically: true, encoding: .utf8)
        try writeManifest(appDestination: appDestination, manifestURL: manifest)

        _ = runProcess(executable: "/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", launchAgent.path])
        let bootstrapped = runProcess(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", launchAgent.path])
        guard bootstrapped.exitCode == 0 else {
            throw DaemonInstallError.commandFailed("launchctl bootstrap", bootstrapped.output)
        }
    }

    private func launchAgentPlist(plan: BrokerInstallPlan) -> String {
        let daemonPath = "\(plan.appDestinationPath)/Contents/MacOS/agentic-secrets-brokerd".xmlEscaped
        let socketPath = plan.socketPath.xmlEscaped
        let manifestPath = plan.manifestPath.xmlEscaped
        let stdoutPath = "\(plan.runDirectoryPath)/core.stdout.log".xmlEscaped
        let stderrPath = "\(plan.runDirectoryPath)/core.stderr.log".xmlEscaped
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.agenticsecrets.broker</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(daemonPath)</string>
            <string>serve</string>
            <string>--socket</string>
            <string>\(socketPath)</string>
            <string>--manifest</string>
            <string>\(manifestPath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(stdoutPath)</string>
          <key>StandardErrorPath</key>
          <string>\(stderrPath)</string>
        </dict>
        </plist>
        """
    }

    private func writeManifest(appDestination: URL, manifestURL: URL) throws {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let helpers = try Self.manifestHelpers.map { helper in
            let path = appDestination.appendingPathComponent("Contents/MacOS/\(helper)").path
            let identity = try SelfBuildPeerValidator.identity(helperName: helper, path: path, version: version)
            return SelfBuildPeerRequirement(
                helperName: identity.helperName,
                resolvedPath: identity.resolvedPath,
                ownerUserID: identity.ownerUserID,
                minimumVersion: version,
                binarySHA256: identity.binarySHA256,
                cdHash: identity.cdHash,
                allowDebugSigned: false
            )
        }
        let manifest = InstallManifest(
            appVersion: version,
            prefix: manifestURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
            installedAt: Date(),
            helpers: helpers
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
    }

    private func unavailableStatus(paths: (socketPath: String, launchAgentPath: String?, recoveryCommand: String), message: String, detail: String? = nil) -> BrokerStatus {
        BrokerStatus(
            state: .unavailable,
            socketPath: paths.socketPath,
            launchAgentPath: paths.launchAgentPath,
            message: message,
            detail: detail,
            recoveryCommand: paths.recoveryCommand,
            checkedAt: Date()
        )
    }

    private func unavailableStatus(paths: (socketPath: String, launchAgentPath: String?, recoveryCommand: String), reason: DaemonUnavailableReason, detail: String?) -> BrokerStatus {
        unavailableStatus(paths: paths, message: reason.message, detail: detail)
    }

    private func daemonUnavailableReason(_ error: Error) -> DaemonUnavailableReason {
        let description = String(describing: error)
        let plan = makeInstallPlan()
        if !plan.currentAppIsInstalledCopy && FileManager.default.fileExists(atPath: plan.appDestinationPath) {
            return .wrongAppCopy
        }
        if description.contains("No such file or directory") || description.contains("connect") {
            return FileManager.default.fileExists(atPath: plan.launchAgentPath) ? .notRunning : .notInstalled
        }
        if description.contains("unauthorizedPeer") || description.contains("wrongHash") || description.contains("wrongPath") || description.contains("wrongCDHash") {
            return .manifestMismatch
        }
        return .unreachable
    }

    private func runLaunchctl(_ arguments: [String]) -> (exitCode: Int32, output: String) {
        runProcess(executable: "/bin/launchctl", arguments: arguments)
    }

    private func runProcess(executable: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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

    private static func defaultInstallPrefix() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgenticSecrets/LocalInstall", isDirectory: true)
    }

    private static let installExecutables = [
        "AgenticSecrets",
        "agentic-secrets",
        "agentic-secrets-shim",
        "agentic-secrets-brokerd",
        "agentic-secrets-api-sessiond",
        "agentic-secrets-bitwarden-providerd",
        "agentic-secrets-mcpd"
    ]

    private static let manifestHelpers = [
        "AgenticSecrets",
        "agentic-secrets-shim",
        "agentic-secrets-brokerd",
        "agentic-secrets-api-sessiond",
        "agentic-secrets-bitwarden-providerd",
        "agentic-secrets-mcpd"
    ]
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private enum DaemonUnavailableReason {
    case notInstalled
    case notRunning
    case wrongAppCopy
    case manifestMismatch
    case unreachable

    var message: String {
        switch self {
        case .notInstalled:
            "Local daemon is not installed yet."
        case .notRunning:
            "Local daemon is installed but not running."
        case .wrongAppCopy:
            "Open the installed copy so the authenticated IPC manifest matches the running UI."
        case .manifestMismatch:
            "Local daemon trust manifest does not match this app copy."
        case .unreachable:
            "Local daemon is not reachable."
        }
    }
}

private enum DaemonInstallError: Error, CustomStringConvertible {
    case commandFailed(String, String)

    var description: String {
        switch self {
        case .commandFailed(let command, let output):
            "\(command) failed: \(output)"
        }
    }
}

struct StubBrokerStatusController: BrokerStatusControlling {
    var statusValue: BrokerStatus
    var repairValue: BrokerStatus?
    var installPlanValue: BrokerInstallPlan = BrokerInstallPlan(
        supported: true,
        title: "Install Local Daemon",
        summary: "Install will copy this app bundle into the local self-build install prefix and start the broker daemon.",
        prefixPath: "/tmp/agentic-secrets-ui-smoke",
        appSourcePath: "/tmp/AgenticSecrets.app",
        appDestinationPath: "/tmp/agentic-secrets-ui-smoke/Applications/AgenticSecrets.app",
        binDirectoryPath: "/tmp/agentic-secrets-ui-smoke/bin",
        stateDirectoryPath: "/tmp/agentic-secrets-ui-smoke/var/agentic-secrets",
        runDirectoryPath: "/tmp/agentic-secrets-ui-smoke/run/agentic-secrets",
        launchAgentPath: "/tmp/agentic-secrets-ui-smoke/Library/LaunchAgents/com.agenticsecrets.broker.plist",
        manifestPath: "/tmp/agentic-secrets-ui-smoke/var/agentic-secrets/install-manifest.json",
        socketPath: "/tmp/agentic-secrets-ui-smoke/run/agentic-secrets/core.sock",
        commandPreview: "scripts/install_local.sh --load",
        missingExecutables: [],
        currentAppIsInstalledCopy: false
    )
    var installValue: BrokerStatus?

    func status() async -> BrokerStatus {
        statusValue
    }

    func repair() async -> BrokerStatus {
        repairValue ?? statusValue
    }

    func installPlan() async -> BrokerInstallPlan {
        installPlanValue
    }

    func installOrRepair() async -> BrokerStatus {
        installValue ?? repairValue ?? statusValue
    }
}
