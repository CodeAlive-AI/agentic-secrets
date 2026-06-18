import AgenticSecretsBroker
import Foundation
import Security

enum BrokerRunState: String, Codable, Equatable, Sendable {
    case unknown
    case healthy
    case unavailable
    case repairing
    case installing
    case uninstalling
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
    var applicationsShortcutPath: String
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

struct BrokerUninstallPlan: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var prefixPath: String
    var appDestinationPath: String
    var applicationsShortcutPath: String
    var binDirectoryPath: String
    var shimDirectoryPath: String
    var stateDirectoryPath: String
    var runDirectoryPath: String
    var socketDirectoryPath: String
    var launchAgentPath: String
    var managedShellConfigPaths: [String]
    var canUninstall: Bool
}

protocol BrokerStatusControlling: Sendable {
    func status() async -> BrokerStatus
    func repair() async -> BrokerStatus
    func installPlan() async -> BrokerInstallPlan
    func installOrRepair() async -> BrokerStatus
    func uninstallPlan() async -> BrokerUninstallPlan
    func uninstall(purgeLocalState: Bool, removeShellConfiguration: Bool) async -> BrokerStatus
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

    func uninstallPlan() async -> BrokerUninstallPlan {
        makeUninstallPlan()
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
                message: "Install failed. Review Diagnostic & Uninstall and try again.",
                detail: String(describing: error),
                recoveryCommand: plan.commandPreview,
                checkedAt: Date()
            )
        }
    }

    func uninstall(purgeLocalState: Bool, removeShellConfiguration: Bool) async -> BrokerStatus {
        let plan = makeUninstallPlan()
        do {
            try uninstall(plan: plan, purgeLocalState: purgeLocalState, removeShellConfiguration: removeShellConfiguration)
            return BrokerStatus(
                state: .unavailable,
                socketPath: URL(fileURLWithPath: plan.socketDirectoryPath).appendingPathComponent("core.sock").path,
                launchAgentPath: plan.launchAgentPath,
                message: purgeLocalState ? "Local Agentic Secrets install and state were removed." : "Local Agentic Secrets install was removed. Local state was retained.",
                detail: removeShellConfiguration ? "Managed shell PATH entries were removed from known shell startup files when present." : "Managed shell PATH entries were left unchanged.",
                recoveryCommand: "scripts/install_local.sh --load",
                checkedAt: Date()
            )
        } catch {
            return BrokerStatus(
                state: .unavailable,
                socketPath: URL(fileURLWithPath: plan.socketDirectoryPath).appendingPathComponent("core.sock").path,
                launchAgentPath: plan.launchAgentPath,
                message: "Uninstall failed. Review Diagnostic & Uninstall and try again.",
                detail: String(describing: error),
                recoveryCommand: "scripts/uninstall_local.sh --purge-local-state",
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
        let applicationsShortcut = Self.userApplicationsShortcut()
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
            summary = "Repair will refresh the Applications shortcut, helper links, the install manifest, and the per-user LaunchAgent."
        } else {
            summary = "Install will copy this app bundle into the local self-build install prefix, add a user Applications shortcut, and start the broker daemon."
        }
        return BrokerInstallPlan(
            supported: supported,
            title: currentInstalled ? "Repair Local Install" : "Install Local Daemon",
            summary: summary,
            prefixPath: prefix.path,
            appSourcePath: source.path,
            appDestinationPath: appDestination.path,
            applicationsShortcutPath: applicationsShortcut.path,
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

    private func makeUninstallPlan() -> BrokerUninstallPlan {
        let prefix = IPCControlPlaneClient.installPrefixFromBundle() ?? Self.defaultInstallPrefix()
        let appDestination = prefix.appendingPathComponent("Applications/AgenticSecrets.app")
        let applicationsShortcut = Self.userApplicationsShortcut()
        let binDirectory = prefix.appendingPathComponent("bin", isDirectory: true)
        let shimDirectory = prefix.appendingPathComponent("shims", isDirectory: true)
        let stateDirectory = prefix.appendingPathComponent("var/agentic-secrets", isDirectory: true)
        let runDirectory = prefix.appendingPathComponent("run/agentic-secrets", isDirectory: true)
        let socketDirectory = URL(fileURLWithPath: IPCControlPlaneClient.defaultRuntimeSocketPath()).deletingLastPathComponent()
        let launchAgent = prefix.appendingPathComponent("Library/LaunchAgents/com.agenticsecrets.broker.plist")
        let shellConfigs = Self.managedShellConfigPaths().map(\.path)
        let canUninstall = FileManager.default.fileExists(atPath: prefix.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: applicationsShortcut.path)) != nil
            || FileManager.default.fileExists(atPath: socketDirectory.path)
            || FileManager.default.fileExists(atPath: launchAgent.path)
            || Self.managedShellConfigPaths().contains { FileManager.default.fileExists(atPath: $0.path) }
        return BrokerUninstallPlan(
            title: "Remove Local Install",
            summary: "Remove the local app copy, Applications shortcut, helper links, command shims, runtime files, socket directory, and per-user LaunchAgent. Local state is deleted only when explicitly selected.",
            prefixPath: prefix.path,
            appDestinationPath: appDestination.path,
            applicationsShortcutPath: applicationsShortcut.path,
            binDirectoryPath: binDirectory.path,
            shimDirectoryPath: shimDirectory.path,
            stateDirectoryPath: stateDirectory.path,
            runDirectoryPath: runDirectory.path,
            socketDirectoryPath: socketDirectory.path,
            launchAgentPath: launchAgent.path,
            managedShellConfigPaths: shellConfigs,
            canUninstall: canUninstall
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
        let applicationsShortcut = URL(fileURLWithPath: plan.applicationsShortcutPath)

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

        try createManagedUserApplicationsShortcut(at: applicationsShortcut, appDestination: appDestination)

        try launchAgentPlist(plan: plan).write(to: launchAgent, atomically: true, encoding: .utf8)
        try writeManifest(appDestination: appDestination, manifestURL: manifest)

        _ = runProcess(executable: "/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", launchAgent.path])
        let bootstrapped = runProcess(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", launchAgent.path])
        guard bootstrapped.exitCode == 0 else {
            throw DaemonInstallError.commandFailed("launchctl bootstrap", bootstrapped.output)
        }
    }

    private func uninstall(plan: BrokerUninstallPlan, purgeLocalState: Bool, removeShellConfiguration: Bool) throws {
        let fileManager = FileManager.default
        let launchAgent = URL(fileURLWithPath: plan.launchAgentPath)
        let binDirectory = URL(fileURLWithPath: plan.binDirectoryPath, isDirectory: true)
        let shimDirectory = URL(fileURLWithPath: plan.shimDirectoryPath, isDirectory: true)
        let appDestination = URL(fileURLWithPath: plan.appDestinationPath, isDirectory: true)
        let applicationsShortcut = URL(fileURLWithPath: plan.applicationsShortcutPath)
        let runDirectory = URL(fileURLWithPath: plan.runDirectoryPath, isDirectory: true)
        let socketDirectory = URL(fileURLWithPath: plan.socketDirectoryPath, isDirectory: true)
        let stateDirectory = URL(fileURLWithPath: plan.stateDirectoryPath, isDirectory: true)

        if fileManager.fileExists(atPath: launchAgent.path) {
            _ = runProcess(executable: "/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", launchAgent.path])
        }

        removeManagedShims(in: shimDirectory, appDestination: appDestination)
        removeManagedUserApplicationsShortcut(at: applicationsShortcut, appDestination: appDestination)
        try? fileManager.removeItem(at: shimDirectory)

        for executable in Self.installExecutables {
            try? fileManager.removeItem(at: binDirectory.appendingPathComponent(executable))
        }

        try? fileManager.removeItem(at: launchAgent)
        try? fileManager.removeItem(at: runDirectory)
        try? fileManager.removeItem(at: socketDirectory)
        try? fileManager.removeItem(at: appDestination)
        if purgeLocalState {
            removeStateKeychainItems(stateDirectory: stateDirectory)
            try? fileManager.removeItem(at: stateDirectory)
        }
        if removeShellConfiguration {
            try ShellConfigurationCleaner.removeManagedBlocks(
                from: plan.managedShellConfigPaths.map { URL(fileURLWithPath: $0) },
                managedDirectories: [binDirectory.path, shimDirectory.path]
            )
        }
        removeEmptyDirectories(from: URL(fileURLWithPath: plan.prefixPath, isDirectory: true))
    }

    private func removeManagedShims(in shimDirectory: URL, appDestination: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: shimDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        let expectedTargets = Set([
            appDestination.appendingPathComponent("Contents/MacOS/agentic-secrets-shim").path,
            appDestination.appendingPathComponent("Contents/MacOS/agentic-secrets-shim").standardizedFileURL.path
        ])
        for entry in entries where expectedTargets.contains(entry.resolvingSymlinksInPath().path) {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func createManagedUserApplicationsShortcut(at shortcut: URL, appDestination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: shortcut.deletingLastPathComponent(), withIntermediateDirectories: true)
        removeManagedUserApplicationsShortcut(at: shortcut, appDestination: appDestination)
        guard !itemExistsOrSymlink(at: shortcut) else { return }
        try fileManager.createSymbolicLink(at: shortcut, withDestinationURL: appDestination)
    }

    private func removeManagedUserApplicationsShortcut(at shortcut: URL, appDestination: URL) {
        let fileManager = FileManager.default
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: shortcut.path) else { return }
        let targetURL = URL(fileURLWithPath: target)
        let expected = Set([
            appDestination.path,
            appDestination.standardizedFileURL.path
        ])
        guard expected.contains(target) || expected.contains(targetURL.standardizedFileURL.path) else { return }
        try? fileManager.removeItem(at: shortcut)
    }

    private func itemExistsOrSymlink(at url: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func removeEmptyDirectories(from prefix: URL) {
        let fileManager = FileManager.default
        var current = prefix
        while current.path != fileManager.homeDirectoryForCurrentUser.path && current.path != "/" {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: current.path), entries.isEmpty else { break }
            try? fileManager.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    private func removeStateKeychainItems(stateDirectory: URL) {
        let account = "local-state:" + shortDigest(stateDirectory.standardizedFileURL.path, length: 24)
        for service in ["com.agenticsecrets.cli-registry-integrity", "com.agenticsecrets.cli-persistent-allow"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
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

    private static func userApplicationsShortcut() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/AgenticSecrets.app", isDirectory: true)
    }

    private static func managedShellConfigPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".bashrc", ".profile"].map { home.appendingPathComponent($0) }
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

enum ShellConfigurationCleaner {
    static func removeManagedBlocks(from files: [URL], managedDirectories: [String]) throws {
        for file in files {
            try removeManagedBlocks(from: file, managedDirectories: managedDirectories)
        }
    }

    static func removeManagedBlocks(from file: URL, managedDirectories: [String]) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: file.path) else { return }
        let originalAttributes = try? fileManager.attributesOfItem(atPath: file.path)
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else { return }
        let cleaned = removeManagedBlocks(from: text, managedDirectories: managedDirectories)
        guard cleaned != text else { return }
        try Data(cleaned.utf8).write(to: file, options: [.atomic])
        if let mode = originalAttributes?[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
    }

    static func removeManagedBlocks(from text: String, managedDirectories: [String]) -> String {
        let lines = text.components(separatedBy: "\n")
        var cleaned: [String] = []
        var index = 0
        while index < lines.count {
            if let endIndex = managedBlockEnd(startingAt: index, in: lines),
               blockContainsManagedDirectory(lines[index...endIndex], managedDirectories: managedDirectories) {
                if cleaned.last == "" {
                    cleaned.removeLast()
                }
                index = endIndex + 1
                continue
            }
            cleaned.append(lines[index])
            index += 1
        }
        return cleaned.joined(separator: "\n")
    }

    private static func managedBlockEnd(startingAt index: Int, in lines: [String]) -> Int? {
        guard index + 1 < lines.count else { return nil }
        let marker = lines[index].trimmingCharacters(in: .whitespaces)
        guard marker == "# Agentic Secrets PATH" || marker == "# AgenticSecrets CLI shims" else { return nil }
        guard lines[index + 1].trimmingCharacters(in: .whitespaces) == #"case ":$PATH:" in"# else { return nil }
        var cursor = index + 2
        while cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces) == "esac" {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func blockContainsManagedDirectory(_ block: ArraySlice<String>, managedDirectories: [String]) -> Bool {
        block.contains { line in
            managedDirectories.contains { directory in
                !directory.isEmpty && line.contains(directory)
            }
        }
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
        applicationsShortcutPath: "/tmp/agentic-secrets-ui-smoke-home/Applications/AgenticSecrets.app",
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
    var uninstallPlanValue: BrokerUninstallPlan = BrokerUninstallPlan(
        title: "Remove Local Install",
        summary: "Remove the local app copy, helper links, command shims, runtime files, socket directory, and per-user LaunchAgent.",
        prefixPath: "/tmp/agentic-secrets-ui-smoke",
        appDestinationPath: "/tmp/agentic-secrets-ui-smoke/Applications/AgenticSecrets.app",
        applicationsShortcutPath: "/tmp/agentic-secrets-ui-smoke-home/Applications/AgenticSecrets.app",
        binDirectoryPath: "/tmp/agentic-secrets-ui-smoke/bin",
        shimDirectoryPath: "/tmp/agentic-secrets-ui-smoke/shims",
        stateDirectoryPath: "/tmp/agentic-secrets-ui-smoke/var/agentic-secrets",
        runDirectoryPath: "/tmp/agentic-secrets-ui-smoke/run/agentic-secrets",
        socketDirectoryPath: "/tmp/agentic-secrets-ui-smoke/run/agentic-secrets",
        launchAgentPath: "/tmp/agentic-secrets-ui-smoke/Library/LaunchAgents/com.agenticsecrets.broker.plist",
        managedShellConfigPaths: [],
        canUninstall: true
    )
    var installValue: BrokerStatus?
    var uninstallValue: BrokerStatus?

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

    func uninstallPlan() async -> BrokerUninstallPlan {
        uninstallPlanValue
    }

    func uninstall(purgeLocalState: Bool, removeShellConfiguration: Bool) async -> BrokerStatus {
        uninstallValue ?? BrokerStatus(
            state: .unavailable,
            socketPath: statusValue.socketPath,
            launchAgentPath: uninstallPlanValue.launchAgentPath,
            message: purgeLocalState ? "Local Agentic Secrets install and state were removed." : "Local Agentic Secrets install was removed. Local state was retained.",
            detail: removeShellConfiguration ? "Managed shell PATH entries were removed from known shell startup files when present." : nil,
            recoveryCommand: "scripts/install_local.sh --load",
            checkedAt: Date()
        )
    }
}
