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
            "Open Installed Copy"
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

struct ProxySessionPresentation: Equatable {
    var profileName: String
    var endpoint: URL
    var token: String
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
    var selectedProxyProfile: String?
    var selectedMCPProfile: String?
    var selectedBWSBinding: String?
    var selectedAdapter: String?
    var searchText = ""
    var isLoading = false
    var errorMessage: String?
    var successMessage: String?
    var showingRegisterCLI = false
    var showingProxyProfileEditor = false
    var showingMCPProfileEditor = false
    var showingBWSBindingEditor = false
    var exportedAudit: String?
    var oneTimeProxySession: ProxySessionPresentation?

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

    var menuBarRecentActivityTitles: [String] {
        guard let snapshot else { return [] }
        return snapshot.auditEvents.prefix(3).map(Self.menuBarActivityTitle)
    }

    var canRegisterCLI: Bool {
        daemonStatus.state == .healthy
    }

    var canManageCoreState: Bool {
        daemonStatus.state == .healthy
    }

    var canExportAudit: Bool {
        snapshot != nil && canManageCoreState
    }

    var canClearUnlockGrants: Bool {
        snapshot?.unlockGrants.isEmpty == false && canManageCoreState
    }

    var canOpenInstalledApp: Bool {
        guard let daemonInstallPlan else { return false }
        guard !daemonInstallPlan.currentAppIsInstalledCopy else { return false }
        return FileManager.default.fileExists(atPath: daemonInstallPlan.appDestinationPath)
    }

    var usesToolbarSearch: Bool {
        selectedSection == .cliSecrets
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

    var proxyProfiles: [ProxyProfileSummary] {
        snapshot?.proxyProfiles ?? []
    }

    var selectedProxyProfileSummary: ProxyProfileSummary? {
        guard let selectedProxyProfile else { return proxyProfiles.first }
        return proxyProfiles.first { $0.name == selectedProxyProfile }
    }

    var selectedProxySession: ProxySessionPresentation? {
        guard let profileName = selectedProxyProfileSummary?.name else { return nil }
        guard oneTimeProxySession?.profileName == profileName else { return nil }
        return oneTimeProxySession
    }

    func clearProxySession(profileName: String? = nil) {
        guard let profileName else {
            oneTimeProxySession = nil
            return
        }
        if oneTimeProxySession?.profileName == profileName {
            oneTimeProxySession = nil
        }
    }

    var mcpProfiles: [MCPProfileSummary] {
        snapshot?.mcpProfiles ?? []
    }

    var selectedMCPProfileSummary: MCPProfileSummary? {
        guard let selectedMCPProfile else { return mcpProfiles.first }
        return mcpProfiles.first { $0.name == selectedMCPProfile }
    }

    var bwsBindings: [BWSBindingSummary] {
        snapshot?.bwsBindings ?? []
    }

    var selectedBWSBindingSummary: BWSBindingSummary? {
        guard let selectedBWSBinding else { return bwsBindings.first }
        return bwsBindings.first { $0.alias == selectedBWSBinding }
    }

    var adapters: [AdapterSummary] {
        snapshot?.adapters ?? []
    }

    var selectedAdapterSummary: AdapterSummary? {
        guard let selectedAdapter else { return adapters.first }
        return adapters.first { $0.adapterID == selectedAdapter }
    }

    func presentRegisterCLI() {
        guard canRegisterCLI else {
            showDaemonRepairGuidance()
            return
        }
        selectedSection = .cliSecrets
        showingRegisterCLI = true
    }

    func presentProxyProfileEditor() {
        guard canManageCoreState else {
            showDaemonRepairGuidance()
            return
        }
        selectedSection = .proxy
        showingProxyProfileEditor = true
    }

    func presentMCPProfileEditor() {
        guard canManageCoreState else {
            showDaemonRepairGuidance()
            return
        }
        selectedSection = .mcp
        showingMCPProfileEditor = true
    }

    func presentBWSBindingEditor() {
        guard canManageCoreState else {
            showDaemonRepairGuidance()
            return
        }
        selectedSection = .bws
        showingBWSBindingEditor = true
    }

    func presentDiagnostics() {
        selectedSection = .diagnostics
    }

    func showDaemonRepairGuidance() {
        selectedSection = .diagnostics
        successMessage = nil
        errorMessage = "Local daemon is not ready. Use Diagnostics to install or repair it."
    }

    func clearFeedback() {
        errorMessage = nil
        successMessage = nil
    }

    func clearSuccessIfCurrent(_ message: String) {
        guard errorMessage == nil, successMessage == message else { return }
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
            maintainSelections()
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

    func refreshAfterActivation() async {
        guard !isLoading else { return }
        if snapshot == nil {
            await refresh()
        } else {
            await checkDaemon()
        }
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

    @discardableResult
    func registerCLI(name: String, targetPath: String, environmentSecrets: [String: String], installShim: Bool) async -> Bool {
        guard canRegisterCLI else {
            showDaemonRepairGuidance()
            return false
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetPath = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecrets = normalizedEnvironmentSecrets(environmentSecrets)
        guard !normalizedName.isEmpty else {
            setInputError(.missingField("CLI name"))
            return false
        }
        guard !normalizedTargetPath.isEmpty else {
            setInputError(.missingField("executable path"))
            return false
        }
        if let message = ExecutablePathSelection.statusMessage(for: normalizedTargetPath) {
            setInputError(.invalidExecutablePath(message))
            return false
        }
        guard !normalizedSecrets.isEmpty else {
            setInputError(.missingField("environment secret"))
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let summary = try await client.registerCLI(ManagementCLIRegistrationRequest(name: normalizedName, targetPath: normalizedTargetPath, environmentSecrets: normalizedSecrets))
            selectedCLI = summary.name
            showingRegisterCLI = false
            if installShim {
                do {
                    _ = try CLIShimInstaller.install(name: summary.name)
                    successMessage = "CLI registered and shim installed"
                    errorMessage = nil
                } catch {
                    successMessage = nil
                    errorMessage = "CLI registered, but the command shim could not be installed: \(userFacingError(error))"
                }
            } else {
                successMessage = "CLI registered"
                errorMessage = nil
            }
            snapshot = try await client.loadSnapshot()
            maintainSelections()
            return true
        } catch {
            errorMessage = userFacingError(error)
            return false
        }
    }

    @discardableResult
    func unregisterSelectedCLI(deleteSecretMaterial: Bool) async -> Bool {
        guard let selectedCLI else { return false }
        return await unregisterCLI(name: selectedCLI, deleteSecretMaterial: deleteSecretMaterial)
    }

    @discardableResult
    func unregisterCLI(name: String, deleteSecretMaterial: Bool) async -> Bool {
        return await runAction("CLI unregistered") {
            _ = try await client.unregisterCLI(ManagementNameRequest(name: name, deleteSecretMaterial: deleteSecretMaterial))
            if self.selectedCLI == name {
                self.selectedCLI = nil
            }
        }
    }

    @discardableResult
    func refreshTrust(for name: String) async -> Bool {
        await runAction("Trust refreshed") {
            _ = try await client.refreshCLITrust(ManagementNameRequest(name: name))
        }
    }

    @discardableResult
    func installShim(for name: String) async -> Bool {
        await runAction("Command shim installed") {
            _ = try CLIShimInstaller.install(name: name)
        }
    }

    @discardableResult
    func uninstallShim(for name: String) async -> Bool {
        await runAction("Command shim removed") {
            _ = try CLIShimInstaller.uninstall(name: name)
        }
    }

    @discardableResult
    func replaceSecret(alias: String, value: String, label: String, environment: String) async -> Bool {
        await runAction("Secret replaced") {
            let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedAlias.isEmpty else { throw InputError.missingField("secret alias") }
            guard hasNonWhitespace(value) else { throw InputError.missingField("secret value") }
            _ = try await client.replaceSecret(ManagementSecretReplacementRequest(
                alias: normalizedAlias,
                value: value,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                environment: environment.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
    }

    @discardableResult
    func deleteSecret(alias: String) async -> Bool {
        await runAction("Secret deleted") {
            try await client.deleteSecret(ManagementSecretDeletionRequest(alias: alias, deleteSecretMaterial: true))
        }
    }

    @discardableResult
    func upsertProxy(name: String, origin: String, pathPrefixes: String, methods: String, secretAlias: String, ttl: TimeInterval) async -> Bool {
        await runAction("Proxy profile saved") {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSecretAlias = secretAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { throw InputError.missingField("profile name") }
            guard !normalizedSecretAlias.isEmpty else { throw InputError.missingField("secret alias") }
            guard (30...3600).contains(ttl) else { throw InputError.invalidTTL }
            let url = try validatedHTTPURL(origin, field: "upstream origin")
            let prefixes = commaList(pathPrefixes)
            let allowedMethods = Set(commaList(methods).map { $0.uppercased() })
            guard !prefixes.isEmpty else { throw InputError.missingField("allowed path prefix") }
            guard prefixes.allSatisfy({ $0.hasPrefix("/") }) else { throw InputError.invalidPathPrefix }
            guard !allowedMethods.isEmpty else { throw InputError.missingField("allowed method") }
            guard allowedMethods.allSatisfy(isHTTPMethodToken) else { throw InputError.invalidHTTPMethod }
            let profile = ProxyProfile(
                name: normalizedName,
                upstreamOrigin: url,
                allowedPathPrefixes: prefixes,
                allowedMethods: allowedMethods,
                secretAlias: normalizedSecretAlias,
                tokenTTLSeconds: ttl
            )
            _ = try await client.upsertProxyProfile(profile)
            selectedProxyProfile = normalizedName
            if oneTimeProxySession?.profileName == normalizedName {
                oneTimeProxySession = nil
            }
        }
    }

    @discardableResult
    func deleteProxyProfile(name: String, deleteSecretAlias: String? = nil) async -> Bool {
        await runAction("Proxy profile deleted") {
            if let deleteSecretAlias {
                try await client.deleteSecret(ManagementSecretDeletionRequest(alias: deleteSecretAlias, deleteSecretMaterial: true))
            }
            try await client.deleteProxyProfile(ManagementNameRequest(name: name))
            if oneTimeProxySession?.profileName == name {
                oneTimeProxySession = nil
            }
            selectedProxyProfile = nil
        }
    }

    @discardableResult
    func upsertMCP(name: String, origin: String, header: String, pathPrefixes: String, allowRedirects: Bool) async -> Bool {
        await runAction("MCP profile saved") {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { throw InputError.missingField("profile name") }
            guard !normalizedHeader.isEmpty else { throw InputError.missingField("authorization header") }
            let url = try validatedHTTPURL(origin, field: "origin")
            let prefixes = commaList(pathPrefixes)
            guard !prefixes.isEmpty else { throw InputError.missingField("allowed path prefix") }
            guard prefixes.allSatisfy({ $0.hasPrefix("/") }) else { throw InputError.invalidPathPrefix }
            let profile = MCPUpstreamProfile(name: normalizedName, origin: url, authorizationHeaderName: normalizedHeader, allowedPathPrefixes: prefixes, allowCrossOriginRedirects: allowRedirects)
            _ = try await client.upsertMCPProfile(profile)
            selectedMCPProfile = normalizedName
        }
    }

    @discardableResult
    func deleteMCPProfile(name: String) async -> Bool {
        await runAction("MCP profile deleted") {
            try await client.deleteMCPProfile(ManagementNameRequest(name: name))
            selectedMCPProfile = nil
        }
    }

    @discardableResult
    func upsertBWSBinding(alias: String, projectID: String, secretID: String, environment: String) async -> Bool {
        await runAction("BWS binding saved") {
            let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSecretID = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedAlias.isEmpty else { throw InputError.missingField("binding alias") }
            guard !normalizedProjectID.isEmpty else { throw InputError.missingField("project ID") }
            guard !normalizedSecretID.isEmpty else { throw InputError.missingField("secret ID") }
            guard ProviderEnvironment(rawValue: environment) != nil else { throw InputError.invalidProviderEnvironment }
            let binding = BWSSecretBinding(alias: normalizedAlias, projectID: normalizedProjectID, secretID: normalizedSecretID, environment: environment)
            let summary = try await client.upsertBWSBinding(binding)
            selectedBWSBinding = summary.alias
        }
    }

    @discardableResult
    func deleteBWSBinding(alias: String) async -> Bool {
        await runAction("BWS binding deleted") {
            try await client.deleteBWSBinding(ManagementNameRequest(name: alias))
            selectedBWSBinding = nil
        }
    }

    @discardableResult
    func installAdapter(payload: AdapterPackPayload) async -> Bool {
        await runAction("Adapter pack installed") {
            let summary = try await client.installAdapter(payload)
            selectedAdapter = summary.adapterID
        }
    }

    @discardableResult
    func revokeAdapter(adapterID: String) async -> Bool {
        await runAction("Adapter revoked") {
            try await client.revokeAdapter(ManagementNameRequest(name: adapterID))
        }
    }

    @discardableResult
    func createProxySession(profileName: String, bindPort: Int) async -> Bool {
        await runAction("Proxy session created") {
            guard !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InputError.missingField("proxy profile") }
            guard (1...65535).contains(bindPort) else { throw InputError.invalidPort }
            let response = try await client.createProxySession(ManagementProxySessionRequest(profileName: profileName, bindPort: bindPort))
            oneTimeProxySession = ProxySessionPresentation(
                profileName: profileName,
                endpoint: response.session.localEndpoint,
                token: response.oneTimeToken
            )
        }
    }

    @discardableResult
    func clearUnlockGrants() async -> Bool {
        await runAction("All grants locked") {
            try await client.clearUnlockGrants()
        }
    }

    @discardableResult
    func exportAudit() async -> Bool {
        await runAction("Audit loaded") {
            exportedAudit = try await client.exportRedactedAuditJSON()
        }
    }

    func loadRedactedAuditForExport() async -> String? {
        guard canExportAudit else {
            showDaemonRepairGuidance()
            return nil
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let audit = try await client.exportRedactedAuditJSON()
            exportedAudit = audit
            errorMessage = nil
            return audit
        } catch {
            errorMessage = userFacingError(error)
            return nil
        }
    }

    func recordAuditExport(to url: URL) {
        successMessage = "Audit exported to \(url.lastPathComponent)"
        errorMessage = nil
    }

    func recordAuditExportFailure(_ error: Error) {
        successMessage = nil
        errorMessage = "Could not export redacted audit: \(userFacingError(error))"
    }

    func recordExternalOpenFailure(label: String, url: URL) {
        successMessage = nil
        errorMessage = "Could not open \(label). Copy this URL instead: \(url.absoluteString)"
    }

    func recordLocalOpenFailure(label: String, path: String) {
        successMessage = nil
        let displayPath = path.isEmpty ? "No path available" : path
        errorMessage = "Could not open \(label). Path is not available: \(displayPath)"
    }

    @discardableResult
    func updateCommandPolicy(destructiveTerms: [String], forbiddenTerms: [String]) async -> Bool {
        await runAction("Command policy saved") {
            _ = try await client.updateCommandPolicy(ManagementCommandPolicyUpdateRequest(
                destructiveTerms: destructiveTerms,
                forbiddenTerms: forbiddenTerms
            ))
        }
    }

    @discardableResult
    private func runAction(_ success: String, action: () async throws -> Void) async -> Bool {
        guard canManageCoreState else {
            showDaemonRepairGuidance()
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await action()
            successMessage = success
            errorMessage = nil
            snapshot = try await client.loadSnapshot()
            maintainSelections()
            return true
        } catch {
            errorMessage = userFacingError(error)
            return false
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

    private func normalizedEnvironmentSecrets(_ environmentSecrets: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (name, value) in environmentSecrets {
            let environmentName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !environmentName.isEmpty, hasNonWhitespace(value) else { continue }
            normalized[environmentName] = value
        }
        return normalized
    }

    private func hasNonWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private func isHTTPMethodToken(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
    }

    private static func menuBarActivityTitle(_ event: AuditEventSummary) -> String {
        shortMenuLabel("\(event.decision) · \(event.flow.rawValue) · \(event.outcome)")
    }

    private static func shortMenuLabel(_ value: String, limit: Int = 30) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: max(0, limit - 1))
        return "\(value[..<end])…"
    }

    private func validatedHTTPURL(_ value: String, field: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            throw InputError.invalidURL(field)
        }
        return url
    }

    private func setInputError(_ error: InputError) {
        successMessage = nil
        errorMessage = error.description
    }

    private func maintainSelections() {
        if let selectedCLI, snapshot?.cliRegistrations.contains(where: { $0.name == selectedCLI }) != true {
            self.selectedCLI = snapshot?.cliRegistrations.first?.name
        }
        if selectedCLI == nil {
            selectedCLI = snapshot?.cliRegistrations.first?.name
        }
        if let selectedProxyProfile, !proxyProfiles.contains(where: { $0.name == selectedProxyProfile }) {
            self.selectedProxyProfile = proxyProfiles.first?.name
        }
        if selectedProxyProfile == nil {
            selectedProxyProfile = proxyProfiles.first?.name
        }
        if let oneTimeProxySession, !proxyProfiles.contains(where: { $0.name == oneTimeProxySession.profileName }) {
            self.oneTimeProxySession = nil
        }
        if let selectedMCPProfile, !mcpProfiles.contains(where: { $0.name == selectedMCPProfile }) {
            self.selectedMCPProfile = mcpProfiles.first?.name
        }
        if selectedMCPProfile == nil {
            selectedMCPProfile = mcpProfiles.first?.name
        }
        if let selectedBWSBinding, !bwsBindings.contains(where: { $0.alias == selectedBWSBinding }) {
            self.selectedBWSBinding = bwsBindings.first?.alias
        }
        if selectedBWSBinding == nil {
            selectedBWSBinding = bwsBindings.first?.alias
        }
        if let selectedAdapter, !adapters.contains(where: { $0.adapterID == selectedAdapter }) {
            self.selectedAdapter = adapters.first?.adapterID
        }
        if selectedAdapter == nil {
            selectedAdapter = adapters.first?.adapterID
        }
    }

    enum InputError: Error, CustomStringConvertible {
        case missingField(String)
        case invalidURL(String)
        case invalidProviderEnvironment
        case invalidTTL
        case invalidPort
        case invalidExecutablePath(String)
        case invalidPathPrefix
        case invalidHTTPMethod

        var description: String {
            switch self {
            case .missingField(let field):
                return "Enter \(field) before saving."
            case .invalidURL(let field):
                return "Enter a valid http or https URL for \(field)."
            case .invalidProviderEnvironment:
                return "Choose a valid provider environment."
            case .invalidTTL:
                return "Choose a token TTL between 30 and 3600 seconds."
            case .invalidPort:
                return "Choose a bind port between 1 and 65535."
            case .invalidExecutablePath(let message):
                return message
            case .invalidPathPrefix:
                return "Path prefixes must start with /."
            case .invalidHTTPMethod:
                return "Use comma-separated HTTP methods such as GET, POST, PATCH."
            }
        }
    }
}
