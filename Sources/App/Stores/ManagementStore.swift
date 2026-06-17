import AgenticFortressCore
import Observation
import SwiftUI

enum ManagementSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case cliSecrets = "CLI & Secrets"
    case proxy = "Proxy"
    case mcp = "MCP"
    case bws = "BWS"
    case adapters = "Adapters"
    case audit = "Audit"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cliSecrets: "terminal"
        case .proxy: "point.3.connected.trianglepath.dotted"
        case .mcp: "server.rack"
        case .bws: "key.horizontal"
        case .adapters: "puzzlepiece.extension"
        case .audit: "list.bullet.clipboard"
        case .diagnostics: "stethoscope"
        }
    }
}

enum DaemonNextAction: Equatable {
    case check
    case installOrRepair
    case restart
    case openInstalledApp

    var title: String {
        switch self {
        case .check:
            "Check Again"
        case .installOrRepair:
            "Repair Local Daemon"
        case .restart:
            "Restart Daemon"
        case .openInstalledApp:
            "Open Installed App"
        }
    }

    func title(plan: DaemonInstallPlan?) -> String {
        self == .installOrRepair ? (plan?.primaryActionTitle ?? "Install Local Daemon") : title
    }

    var systemImage: String {
        switch self {
        case .check:
            "arrow.clockwise"
        case .installOrRepair:
            "wrench.and.screwdriver"
        case .restart:
            "restart"
        case .openInstalledApp:
            "arrow.up.forward.app"
        }
    }
}

@Observable
@MainActor
final class ManagementStore {
    var snapshot: ManagementSnapshot?
    var daemonInstallPlan: DaemonInstallPlan?
    var daemonStatus: DaemonStatus = DaemonStatus(
        state: .unknown,
        socketPath: IPCAgenticFortressClient.defaultPaths().socketPath,
        launchAgentPath: IPCAgenticFortressClient.installPrefixFromBundle()?.appendingPathComponent("Library/LaunchAgents/com.agenticfortress.core.plist").path,
        message: "Daemon status has not been checked yet.",
        detail: nil,
        recoveryCommand: "scripts/install_local.sh --load",
        checkedAt: Date(timeIntervalSince1970: 0)
    )
    var selectedSection: ManagementSection = .overview
    var selectedCLI: String?
    var searchText = ""
    var isLoading = false
    var errorMessage: String?
    var successMessage: String?
    var showingRegisterCLI = false
    var showingProxyProfileEditor = false
    var showingMCPProfileEditor = false
    var exportedAudit: String?
    var oneTimeProxyToken: String?

    private let client: any AgenticFortressClient
    private let daemonController: any DaemonStatusControlling

    init(client: any AgenticFortressClient, daemonController: (any DaemonStatusControlling)? = nil) {
        self.client = client
        self.daemonController = daemonController ?? LocalDaemonStatusController(client: client)
    }

    var menuBarSymbol: String {
        if daemonStatus.state == .unavailable {
            return "exclamationmark.triangle"
        } else if daemonStatus.state == .installing || daemonStatus.state == .repairing {
            return "arrow.clockwise"
        }
        return switch snapshot?.securityHealth.status {
        case .ok: "shield.checkered"
        case .attention: "exclamationmark.shield"
        case .locked: "lock.shield"
        case nil: "shield"
        }
    }

    var menuBarSummary: String {
        if daemonStatus.state == .unavailable {
            return "Daemon unavailable"
        } else if daemonStatus.state == .installing {
            return "Installing daemon"
        } else if daemonStatus.state == .repairing {
            return "Restarting daemon"
        }
        guard let snapshot else { return "Status unavailable" }
        return "\(snapshot.securityHealth.status.rawValue.capitalized) · \(snapshot.unlockGrants.count) grants"
    }

    var canRegisterCLI: Bool {
        daemonStatus.state == .healthy
    }

    var canManageCoreState: Bool {
        daemonStatus.state == .healthy
    }

    var canExportAudit: Bool {
        snapshot != nil
    }

    var canClearUnlockGrants: Bool {
        snapshot?.unlockGrants.isEmpty == false
    }

    var bestDaemonAction: DaemonNextAction? {
        switch daemonStatus.state {
        case .healthy, .installing, .repairing:
            return nil
        case .unknown:
            return .check
        case .unavailable:
            guard let plan = daemonInstallPlan else {
                return daemonStatus.canRepair ? .restart : .check
            }
            if !plan.currentAppIsInstalledCopy && FileManager.default.fileExists(atPath: plan.appDestinationPath) {
                return .openInstalledApp
            }
            if plan.canInstall {
                return .installOrRepair
            }
            if daemonStatus.canRepair {
                return .restart
            }
            return .check
        }
    }

    var filteredCLIRegistrations: [CLIRegistrationSummary] {
        let items = snapshot?.cliRegistrations ?? []
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.targetPath.localizedCaseInsensitiveContains(searchText)
                || $0.environmentBindings.contains { $0.environmentName.localizedCaseInsensitiveContains(searchText) || $0.secretAlias.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var selectedCLIRegistration: CLIRegistrationSummary? {
        guard let selectedCLI else { return filteredCLIRegistrations.first }
        return filteredCLIRegistrations.first { $0.name == selectedCLI }
    }

    func presentRegisterCLI() {
        selectedSection = .cliSecrets
        showingRegisterCLI = true
    }

    func presentProxyProfileEditor() {
        selectedSection = .proxy
        showingProxyProfileEditor = true
    }

    func presentMCPProfileEditor() {
        selectedSection = .mcp
        showingMCPProfileEditor = true
    }

    func presentDiagnostics() {
        selectedSection = .diagnostics
    }

    func clearFeedback() {
        errorMessage = nil
        successMessage = nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        daemonInstallPlan = await daemonController.installPlan()
        daemonStatus = await daemonController.status()
        do {
            snapshot = try await client.loadSnapshot()
            if daemonStatus.state != .healthy {
                daemonStatus = await daemonController.status()
            }
            if selectedCLI == nil {
                selectedCLI = snapshot?.cliRegistrations.first?.name
            }
            errorMessage = nil
        } catch {
            if daemonStatus.state == .unavailable || daemonStatus.state == .installing || daemonStatus.state == .repairing {
                errorMessage = nil
            } else if isDaemonReachabilityError(error) {
                await recoverFromTransientDaemonRefreshError()
            } else {
                errorMessage = userFacingError(error)
            }
        }
    }

    func checkDaemon() async {
        daemonInstallPlan = await daemonController.installPlan()
        daemonStatus = await daemonController.status()
    }

    func repairDaemon() async {
        isLoading = true
        daemonStatus = DaemonStatus(
            state: .repairing,
            socketPath: daemonStatus.socketPath,
            launchAgentPath: daemonStatus.launchAgentPath,
            message: "Restarting core daemon...",
            detail: nil,
            recoveryCommand: daemonStatus.recoveryCommand,
            checkedAt: Date()
        )
        daemonStatus = await daemonController.repair()
        isLoading = false
        if daemonStatus.state == .healthy {
            await refresh()
        }
    }

    func installOrRepairDaemon() async {
        isLoading = true
        let plan: DaemonInstallPlan
        if let daemonInstallPlan {
            plan = daemonInstallPlan
        } else {
            plan = await daemonController.installPlan()
        }
        daemonStatus = DaemonStatus(
            state: .installing,
            socketPath: plan.socketPath,
            launchAgentPath: plan.launchAgentPath,
            message: plan.currentAppIsInstalledCopy ? "Repairing local daemon install..." : "Installing local daemon...",
            detail: nil,
            recoveryCommand: plan.commandPreview,
            checkedAt: Date()
        )
        daemonStatus = await daemonController.installOrRepair()
        daemonInstallPlan = await daemonController.installPlan()
        isLoading = false
        if daemonStatus.state == .healthy {
            await refresh()
        }
    }

    func registerCLI(name: String, targetPath: String, environmentSecrets: [String: String]) async {
        await runAction("CLI registered") {
            let summary = try await client.registerCLI(ManagementCLIRegistrationRequest(name: name, targetPath: targetPath, environmentSecrets: environmentSecrets))
            selectedCLI = summary.name
            showingRegisterCLI = false
        }
    }

    func unregisterSelectedCLI(deleteSecretMaterial: Bool) async {
        guard let selectedCLI else { return }
        await runAction("CLI unregistered") {
            _ = try await client.unregisterCLI(ManagementNameRequest(name: selectedCLI, deleteSecretMaterial: deleteSecretMaterial))
            self.selectedCLI = nil
        }
    }

    func refreshTrust(for name: String) async {
        await runAction("Trust refreshed") {
            _ = try await client.refreshCLITrust(ManagementNameRequest(name: name))
        }
    }

    func replaceSecret(alias: String, value: String, label: String, environment: String) async {
        await runAction("Secret replaced") {
            _ = try await client.replaceSecret(ManagementSecretReplacementRequest(alias: alias, value: value, label: label, environment: environment))
        }
    }

    func deleteSecret(alias: String) async {
        await runAction("Secret deleted") {
            try await client.deleteSecret(ManagementSecretDeletionRequest(alias: alias, deleteSecretMaterial: true))
        }
    }

    func upsertProxy(name: String, origin: String, pathPrefixes: String, methods: String, secretAlias: String, ttl: TimeInterval) async {
        await runAction("Proxy profile saved") {
            guard let url = URL(string: origin) else { throw InputError.invalidURL }
            let profile = ProxyProfile(
                name: name,
                upstreamOrigin: url,
                allowedPathPrefixes: commaList(pathPrefixes),
                allowedMethods: Set(commaList(methods).map { $0.uppercased() }),
                secretAlias: secretAlias,
                tokenTTLSeconds: ttl
            )
            _ = try await client.upsertProxyProfile(profile)
        }
    }

    func upsertMCP(name: String, origin: String, header: String, pathPrefixes: String, allowRedirects: Bool) async {
        await runAction("MCP profile saved") {
            guard let url = URL(string: origin) else { throw InputError.invalidURL }
            let profile = MCPUpstreamProfile(name: name, origin: url, authorizationHeaderName: header, allowedPathPrefixes: commaList(pathPrefixes), allowCrossOriginRedirects: allowRedirects)
            _ = try await client.upsertMCPProfile(profile)
        }
    }

    func installAdapter(payload: AdapterPackPayload) async {
        await runAction("Adapter pack installed") {
            _ = try await client.installAdapter(payload)
        }
    }

    func createProxySession(profileName: String, bindPort: Int) async {
        await runAction("Proxy session created") {
            let response = try await client.createProxySession(ManagementProxySessionRequest(profileName: profileName, bindPort: bindPort))
            oneTimeProxyToken = response.oneTimeToken
        }
    }

    func clearUnlockGrants() async {
        await runAction("Unlock grants cleared") {
            try await client.clearUnlockGrants()
        }
    }

    func exportAudit() async {
        await runAction("Audit exported") {
            exportedAudit = try await client.exportRedactedAuditJSON()
        }
    }

    private func runAction(_ success: String, action: () async throws -> Void) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await action()
            successMessage = success
            errorMessage = nil
            snapshot = try await client.loadSnapshot()
        } catch {
            errorMessage = userFacingError(error)
        }
    }

    private func userFacingError(_ error: Error) -> String {
        let description = String(describing: error)
        if isDaemonReachabilityError(error) {
            return "Local daemon is not reachable. Open Diagnostics to install or repair it."
        }
        return description
    }

    private func isDaemonReachabilityError(_ error: Error) -> Bool {
        let description = String(describing: error)
        return description.contains("socket(") || description.contains("connect:")
    }

    private func recoverFromTransientDaemonRefreshError() async {
        errorMessage = nil
        daemonStatus = await daemonController.status()
        guard daemonStatus.state == .healthy else { return }
        do {
            snapshot = try await client.loadSnapshot()
        } catch {
            errorMessage = isDaemonReachabilityError(error) ? nil : userFacingError(error)
        }
    }

    private func commaList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    enum InputError: Error {
        case invalidURL
    }
}
