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

@Observable
@MainActor
final class ManagementStore {
    var snapshot: ManagementSnapshot?
    var daemonStatus: DaemonStatus = DaemonStatus(
        state: .unknown,
        socketPath: IPCAgenticFortressClient.defaultPaths().socketPath,
        launchAgentPath: IPCAgenticFortressClient.installPrefixFromBundle()?.appendingPathComponent("Library/LaunchAgents/com.agenticfortress.core.plist").path,
        message: "Daemon status has not been checked yet.",
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
        }
        guard let snapshot else { return "Status unavailable" }
        return "\(snapshot.securityHealth.status.rawValue.capitalized) · \(snapshot.unlockGrants.count) grants"
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

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        daemonStatus = await daemonController.status()
        do {
            snapshot = try await client.loadSnapshot()
            if selectedCLI == nil {
                selectedCLI = snapshot?.cliRegistrations.first?.name
            }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func checkDaemon() async {
        daemonStatus = await daemonController.status()
    }

    func repairDaemon() async {
        isLoading = true
        daemonStatus = DaemonStatus(
            state: .repairing,
            socketPath: daemonStatus.socketPath,
            launchAgentPath: daemonStatus.launchAgentPath,
            message: "Restarting core daemon...",
            recoveryCommand: daemonStatus.recoveryCommand,
            checkedAt: Date()
        )
        daemonStatus = await daemonController.repair()
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
            errorMessage = String(describing: error)
        }
    }

    private func commaList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    enum InputError: Error {
        case invalidURL
    }
}
