import AgenticSecretsBroker
import Observation
import SwiftUI

enum ControlPlaneSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case cliSecrets = "CLI Delivery"
    case policyPacks = "CLI Policy"
    case apiSessions = "API Sessions (Proxy)"
    case mcp = "MCP Proxy"
    case bitwardenProviderBindings = "Bitwarden Secrets"
    case audit = "Audit"
    case diagnostics = "Diagnostic & Uninstall"

    var id: String { rawValue }

    static let allCases: [ControlPlaneSection] = [
        .overview,
        .cliSecrets,
        .mcp,
        .bitwardenProviderBindings,
        .audit,
        .diagnostics
    ]

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cliSecrets: "terminal"
        case .apiSessions: "point.3.connected.trianglepath.dotted"
        case .mcp: "server.rack"
        case .bitwardenProviderBindings: "key.horizontal"
        case .policyPacks: "puzzlepiece.extension"
        case .audit: "list.bullet.clipboard"
        case .diagnostics: "stethoscope"
        }
    }

    var isPreview: Bool {
        self == .bitwardenProviderBindings
    }
}

enum BrokerNextAction: Equatable {
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

    func title(plan: BrokerInstallPlan?) -> String {
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

struct APISessionPresentation: Equatable {
    var profileName: String
    var endpoint: URL
    var token: String
}

@Observable
@MainActor
final class ControlPlaneStore {
    var snapshot: ControlPlaneSnapshot?
    var brokerInstallPlan: BrokerInstallPlan?
    var brokerUninstallPlan: BrokerUninstallPlan?
    var brokerStatus: BrokerStatus = BrokerStatus(
        state: .unknown,
        socketPath: IPCControlPlaneClient.defaultPaths().socketPath,
        launchAgentPath: IPCControlPlaneClient.installPrefixFromBundle()?.appendingPathComponent("Library/LaunchAgents/com.agenticsecrets.broker.plist").path,
        message: "Daemon status has not been checked yet.",
        detail: nil,
        recoveryCommand: "scripts/install_local.sh --load",
        checkedAt: Date(timeIntervalSince1970: 0)
    )
    var selectedSection: ControlPlaneSection = .overview
    var selectedCLI: String?
    var selectedAPISessionProfile: String?
    var selectedMCPProfile: String?
    var selectedBitwardenBinding: String?
    var selectedAdapter: String?
    var searchText = ""
    var isLoading = false
    var errorMessage: String?
    var successMessage: String?
    var showingRegisterCLI = false
    var showingAPISessionProfileEditor = false
    var showingMCPProfileEditor = false
    var showingBitwardenBindingEditor = false
    var exportedAudit: String?
    var oneTimeAPISession: APISessionPresentation?
    var availableUpdate: AppUpdateRelease?
    var isCheckingForUpdates = false
    var lastUpdateCheck: Date?

    private let client: any ControlPlaneClient
    private let brokerController: any BrokerStatusControlling
    private let updateChecker: any AppUpdateChecking
    private let updateIgnoreDefaults: UserDefaults
    private static let snapshotLoadRetryDelays: [Duration] = [
        .milliseconds(120),
        .milliseconds(250),
        .milliseconds(500)
    ]
    @ObservationIgnored private var updateCheckTask: Task<Void, Never>?

    init(
        client: any ControlPlaneClient,
        brokerController: (any BrokerStatusControlling)? = nil,
        updateChecker: any AppUpdateChecking = GitHubAppUpdateChecker(),
        updateIgnoreDefaults: UserDefaults = UserDefaults(suiteName: "com.agenticsecrets.updater.ignorelist") ?? .standard
    ) {
        self.client = client
        self.brokerController = brokerController ?? LocalBrokerStatusController(client: client)
        self.updateChecker = updateChecker
        self.updateIgnoreDefaults = updateIgnoreDefaults
    }

    deinit {
        updateCheckTask?.cancel()
    }

    var menuBarSymbol: String {
        if brokerStatus.state == .unavailable {
            return "exclamationmark.triangle"
        } else if brokerStatus.state == .installing || brokerStatus.state == .repairing || brokerStatus.state == .uninstalling {
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
        if brokerStatus.state == .unavailable {
            return "Daemon unavailable"
        } else if brokerStatus.state == .installing {
            return "Installing daemon"
        } else if brokerStatus.state == .repairing {
            return "Restarting daemon"
        } else if brokerStatus.state == .uninstalling {
            return "Removing install"
        }
        guard let snapshot else { return "Status unavailable" }
        return "\(snapshot.securityHealth.status.rawValue.capitalized) · \(snapshot.deliveryGrants.count) grants"
    }

    var updateMenuTitle: String {
        guard let availableUpdate else { return "Check for Updates" }
        let prefix = availableUpdate.critical ? "Critical Update" : "Update"
        return "\(prefix) \(availableUpdate.versionLabel)"
    }

    var menuBarRecentActivityTitles: [String] {
        guard let snapshot else { return [] }
        return snapshot.auditEvents.prefix(3).map(Self.menuBarActivityTitle)
    }

    var canRegisterCLI: Bool {
        brokerStatus.state == .healthy
    }

    var canManageBrokerState: Bool {
        brokerStatus.state == .healthy
    }

    var canExportAudit: Bool {
        snapshot != nil && canManageBrokerState
    }

    var canClearUnlockGrants: Bool {
        snapshot?.deliveryGrants.isEmpty == false && canManageBrokerState
    }

    var canOpenInstalledApp: Bool {
        guard let brokerInstallPlan else { return false }
        guard !brokerInstallPlan.currentAppIsInstalledCopy else { return false }
        return FileManager.default.fileExists(atPath: brokerInstallPlan.appDestinationPath)
    }

    var canUninstallLocalInstall: Bool {
        brokerUninstallPlan?.canUninstall == true && !isLoading
    }

    var usesToolbarSearch: Bool {
        selectedSection == .cliSecrets
    }

    var bestDaemonAction: BrokerNextAction? {
        switch brokerStatus.state {
        case .healthy, .installing, .repairing, .uninstalling:
            return nil
        case .unknown:
            return .check
        case .unavailable:
            guard let plan = brokerInstallPlan else {
                return brokerStatus.canRepair ? .restart : .check
            }
            if brokerStatus.message.contains("Open the installed copy"),
               !plan.currentAppIsInstalledCopy,
               FileManager.default.fileExists(atPath: plan.appDestinationPath) {
                return .openInstalledApp
            }
            if plan.canInstall {
                return .installOrRepair
            }
            if brokerStatus.canRepair {
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

    var apiSessionProfiles: [APISessionProfileSummary] {
        snapshot?.apiSessionProfiles ?? []
    }

    var selectedAPISessionProfileSummary: APISessionProfileSummary? {
        guard let selectedAPISessionProfile else { return apiSessionProfiles.first }
        return apiSessionProfiles.first { $0.name == selectedAPISessionProfile }
    }

    var selectedAPISession: APISessionPresentation? {
        guard let profileName = selectedAPISessionProfileSummary?.name else { return nil }
        guard oneTimeAPISession?.profileName == profileName else { return nil }
        return oneTimeAPISession
    }

    func clearAPISession(profileName: String? = nil) {
        guard let profileName else {
            oneTimeAPISession = nil
            return
        }
        if oneTimeAPISession?.profileName == profileName {
            oneTimeAPISession = nil
        }
    }

    var mcpProfiles: [MCPProfileSummary] {
        snapshot?.mcpProfiles ?? []
    }

    var selectedMCPProfileSummary: MCPProfileSummary? {
        guard let selectedMCPProfile else { return mcpProfiles.first }
        return mcpProfiles.first { $0.name == selectedMCPProfile }
    }

    var bitwardenBindings: [BitwardenBindingSummary] {
        snapshot?.bitwardenBindings ?? []
    }

    var selectedBitwardenBindingSummary: BitwardenBindingSummary? {
        guard let selectedBitwardenBinding else { return bitwardenBindings.first }
        return bitwardenBindings.first { $0.alias == selectedBitwardenBinding }
    }

    var policyPacks: [PolicyPackSummary] {
        snapshot?.policyPacks ?? []
    }

    var selectedPolicyPackSummary: PolicyPackSummary? {
        guard let selectedAdapter else { return policyPacks.first }
        return policyPacks.first { $0.policyPackID == selectedAdapter }
    }

    func presentRegisterCLI() {
        guard canRegisterCLI else {
            showDaemonRepairGuidance()
            return
        }
        selectedSection = .cliSecrets
        showingRegisterCLI = true
    }

    func presentAPISessionProfileEditor() {
        guard canManageBrokerState else {
            showDaemonRepairGuidance()
            return
        }
        selectedSection = .apiSessions
        showingAPISessionProfileEditor = true
    }

    func presentMCPProfileEditor() {
        guard canManageBrokerState else {
            showDaemonRepairGuidance()
            return
        }
        selectedSection = .mcp
        showingMCPProfileEditor = true
    }

    func presentBitwardenBindingEditor() {
        guard canManageBrokerState else {
            showDaemonRepairGuidance()
            return
        }
        selectedSection = .bitwardenProviderBindings
        showingBitwardenBindingEditor = true
    }

    func presentDiagnostics() {
        selectedSection = .diagnostics
    }

    func showDaemonRepairGuidance() {
        selectedSection = .diagnostics
        successMessage = nil
        errorMessage = "Local daemon is not ready. Use Diagnostic & Uninstall to install or repair it."
    }

    func clearFeedback() {
        errorMessage = nil
        successMessage = nil
    }

    func clearSuccessIfCurrent(_ message: String) {
        guard errorMessage == nil, successMessage == message else { return }
        successMessage = nil
    }

    func startAutomaticUpdateChecks() {
        guard updateCheckTask == nil else { return }
        updateCheckTask = Task { [weak self] in
            await self?.checkForUpdates(manual: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                await self?.checkForUpdates(manual: false)
            }
        }
    }

    func checkForUpdates(manual: Bool) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            let update = try await updateChecker.availableUpdate(
                currentVersion: AppVersionInfo.displayVersion,
                osVersion: ProcessInfo.processInfo.operatingSystemVersion
            )
            lastUpdateCheck = Date()
            if let update, !isIgnored(update) {
                availableUpdate = update
                if manual {
                    successMessage = "\(update.displayName) is available"
                    errorMessage = nil
                }
            } else {
                availableUpdate = nil
                if manual {
                    successMessage = "Agentic Secrets is up to date"
                    errorMessage = nil
                }
            }
        } catch {
            if manual {
                successMessage = nil
                errorMessage = "Could not check for updates: \(userFacingError(error))"
            }
        }
    }

    func ignoreAvailableUpdate() {
        guard let update = availableUpdate, !update.critical else { return }
        updateIgnoreDefaults.set(true, forKey: ignoreKey(for: update))
        availableUpdate = nil
        successMessage = "Update ignored"
        errorMessage = nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        brokerInstallPlan = await brokerController.installPlan()
        brokerUninstallPlan = await brokerController.uninstallPlan()
        brokerStatus = await brokerController.status()
        do {
            try await loadSnapshotAfterHealthyStatus()
            errorMessage = nil
        } catch {
            if brokerStatus.state == .unavailable || brokerStatus.state == .installing || brokerStatus.state == .repairing || brokerStatus.state == .uninstalling {
                await recoverFromStartupRaceIfPossible()
            } else {
                snapshot = nil
                errorMessage = localStateLoadError(error)
            }
        }
    }

    func checkDaemon() async {
        brokerInstallPlan = await brokerController.installPlan()
        brokerUninstallPlan = await brokerController.uninstallPlan()
        brokerStatus = await brokerController.status()
    }

    func refreshAfterActivation() async {
        guard !isLoading else { return }
        await refresh()
    }

    func repairDaemon() async {
        isLoading = true
        brokerStatus = BrokerStatus(
            state: .repairing,
            socketPath: brokerStatus.socketPath,
            launchAgentPath: brokerStatus.launchAgentPath,
            message: "Restarting broker daemon...",
            detail: nil,
            recoveryCommand: brokerStatus.recoveryCommand,
            checkedAt: Date()
        )
        brokerStatus = await brokerController.repair()
        isLoading = false
        if brokerStatus.state == .healthy {
            await refresh()
        }
    }

    func installOrRepairDaemon() async {
        isLoading = true
        let plan: BrokerInstallPlan
        if let brokerInstallPlan {
            plan = brokerInstallPlan
        } else {
            plan = await brokerController.installPlan()
        }
        brokerStatus = BrokerStatus(
            state: .installing,
            socketPath: plan.socketPath,
            launchAgentPath: plan.launchAgentPath,
            message: plan.currentAppIsInstalledCopy ? "Repairing local daemon install..." : "Installing local daemon...",
            detail: nil,
            recoveryCommand: plan.commandPreview,
            checkedAt: Date()
        )
        brokerStatus = await brokerController.installOrRepair()
        brokerInstallPlan = await brokerController.installPlan()
        brokerUninstallPlan = await brokerController.uninstallPlan()
        isLoading = false
        if brokerStatus.state == .healthy {
            await refresh()
        }
    }

    @discardableResult
    func uninstallLocalInstall(purgeLocalState: Bool, removeShellConfiguration: Bool) async -> Bool {
        isLoading = true
        let plan: BrokerUninstallPlan
        if let brokerUninstallPlan {
            plan = brokerUninstallPlan
        } else {
            plan = await brokerController.uninstallPlan()
        }
        brokerStatus = BrokerStatus(
            state: .uninstalling,
            socketPath: brokerStatus.socketPath,
            launchAgentPath: plan.launchAgentPath,
            message: "Removing local Agentic Secrets install...",
            detail: nil,
            recoveryCommand: "scripts/uninstall_local.sh --purge-local-state",
            checkedAt: Date()
        )
        brokerStatus = await brokerController.uninstall(
            purgeLocalState: purgeLocalState,
            removeShellConfiguration: removeShellConfiguration
        )
        brokerInstallPlan = await brokerController.installPlan()
        brokerUninstallPlan = await brokerController.uninstallPlan()
        snapshot = nil
        isLoading = false
        if brokerStatus.message.hasPrefix("Uninstall failed") {
            successMessage = nil
            errorMessage = brokerStatus.message
            return false
        } else {
            successMessage = brokerStatus.message
            errorMessage = nil
            return true
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
            let summary = try await client.registerCLI(ControlPlaneCommandLineToolRegistrationRequest(name: normalizedName, targetPath: normalizedTargetPath, environmentSecrets: normalizedSecrets))
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
            do {
                snapshot = try await loadSnapshotWithTransientRetry()
                maintainSelections()
            } catch {
                errorMessage = "\(successMessage ?? "CLI registered"), but the updated local state could not be refreshed. \(localStateLoadError(error))"
            }
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
            _ = try await client.unregisterCLI(ControlPlaneNameRequest(name: name, deleteSecretMaterial: deleteSecretMaterial))
            if self.selectedCLI == name {
                self.selectedCLI = nil
            }
        }
    }

    @discardableResult
    func refreshTrust(for name: String) async -> Bool {
        await runAction("Trust refreshed") {
            _ = try await client.refreshCLITrust(ControlPlaneNameRequest(name: name))
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
            _ = try await client.replaceSecret(ControlPlaneSecretReplacementRequest(
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
            try await client.deleteSecret(ControlPlaneSecretDeletionRequest(alias: alias, deleteSecretMaterial: true))
        }
    }

    @discardableResult
    func upsertAPISessionProfile(name: String, origin: String, pathPrefixes: String, methods: String, secretAlias: String, ttl: TimeInterval) async -> Bool {
        await runAction("API session profile saved") {
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
            let profile = APISessionProfile(
                name: normalizedName,
                upstreamOrigin: url,
                allowedPathPrefixes: prefixes,
                allowedMethods: allowedMethods,
                secretAlias: normalizedSecretAlias,
                tokenTTLSeconds: ttl
            )
            _ = try await client.upsertAPISessionProfile(profile)
            selectedAPISessionProfile = normalizedName
            if oneTimeAPISession?.profileName == normalizedName {
                oneTimeAPISession = nil
            }
        }
    }

    @discardableResult
    func deleteAPISessionProfile(name: String, deleteSecretAlias: String? = nil) async -> Bool {
        await runAction("API session profile deleted") {
            if let deleteSecretAlias {
                try await client.deleteSecret(ControlPlaneSecretDeletionRequest(alias: deleteSecretAlias, deleteSecretMaterial: true))
            }
            try await client.deleteAPISessionProfile(ControlPlaneNameRequest(name: name))
            if oneTimeAPISession?.profileName == name {
                oneTimeAPISession = nil
            }
            selectedAPISessionProfile = nil
        }
    }

    @discardableResult
    func upsertMCP(name: String, origin: String, header: String, authValue: String, existingSecretAlias: String? = nil) async -> Bool {
        await runAction("MCP proxy saved") {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedAuthValue = authValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSecretAlias = existingSecretAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
            let secretAlias = normalizedSecretAlias?.isEmpty == false ? normalizedSecretAlias! : Self.mcpSecretAlias(for: normalizedName)
            guard !normalizedName.isEmpty else { throw InputError.missingField("profile name") }
            guard !normalizedHeader.isEmpty else { throw InputError.missingField("authorization header") }
            guard !normalizedAuthValue.isEmpty || normalizedSecretAlias?.isEmpty == false else { throw InputError.missingField("auth header value") }
            let url = try validatedHTTPURL(origin, field: "origin")
            if !normalizedAuthValue.isEmpty {
                _ = try await client.replaceSecret(ControlPlaneSecretReplacementRequest(
                    alias: secretAlias,
                    value: authValue,
                    label: "\(normalizedName) MCP proxy auth value",
                    environment: "mcp-proxy:\(normalizedName)"
                ))
            }
            let profile = MCPUpstreamProfile(name: normalizedName, origin: url, authorizationHeaderName: normalizedHeader, secretAlias: secretAlias, allowedPathPrefixes: ["/"], allowCrossOriginRedirects: false)
            _ = try await client.upsertMCPProfile(profile)
            selectedMCPProfile = normalizedName
        }
    }

    @discardableResult
    func deleteMCPProfile(name: String) async -> Bool {
        await runAction("MCP proxy deleted") {
            try await client.deleteMCPProfile(ControlPlaneNameRequest(name: name))
            selectedMCPProfile = nil
        }
    }

    private static func mcpSecretAlias(for name: String) -> String {
        let normalized = name
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "." }
        let compact = String(normalized)
            .split(separator: ".")
            .joined(separator: ".")
        return "mcp.\(compact.isEmpty ? "proxy" : compact).auth"
    }

    @discardableResult
    func upsertBitwardenBinding(alias: String, projectID: String, secretID: String, environment: String) async -> Bool {
        await runAction("Bitwarden provider binding saved") {
            let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSecretID = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedAlias.isEmpty else { throw InputError.missingField("binding alias") }
            guard !normalizedProjectID.isEmpty else { throw InputError.missingField("project ID") }
            guard !normalizedSecretID.isEmpty else { throw InputError.missingField("secret ID") }
            guard ProviderEnvironment(rawValue: environment) != nil else { throw InputError.invalidProviderEnvironment }
            let binding = BitwardenSecretBinding(alias: normalizedAlias, projectID: normalizedProjectID, secretID: normalizedSecretID, environment: environment)
            let summary = try await client.upsertBitwardenBinding(binding)
            selectedBitwardenBinding = summary.alias
        }
    }

    @discardableResult
    func deleteBitwardenBinding(alias: String) async -> Bool {
        await runAction("Bitwarden provider binding deleted") {
            try await client.deleteBitwardenBinding(ControlPlaneNameRequest(name: alias))
            selectedBitwardenBinding = nil
        }
    }

    @discardableResult
    func installAdapter(payload: CommandPolicyPackPayload) async -> Bool {
        await runAction("Adapter pack installed") {
            let summary = try await client.installAdapter(payload)
            selectedAdapter = summary.policyPackID
        }
    }

    @discardableResult
    func revokeAdapter(policyPackID: String) async -> Bool {
        await runAction("Command policy pack revoked") {
            try await client.revokeAdapter(ControlPlaneNameRequest(name: policyPackID))
        }
    }

    @discardableResult
    func createAPISession(profileName: String, bindPort: Int) async -> Bool {
        await runAction("API session created") {
            guard !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InputError.missingField("API session profile") }
            guard (1...65535).contains(bindPort) else { throw InputError.invalidPort }
            let response = try await client.createAPISession(ControlPlaneAPISessionRequest(profileName: profileName, bindPort: bindPort))
            oneTimeAPISession = APISessionPresentation(
                profileName: profileName,
                endpoint: response.session.localEndpoint,
                token: response.oneTimeToken
            )
        }
    }

    @discardableResult
    func clearDeliveryGrants() async -> Bool {
        await runAction("All grants locked") {
            try await client.clearDeliveryGrants()
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
            _ = try await client.updateCommandPolicy(ControlPlaneCommandPolicyUpdateRequest(
                destructiveTerms: destructiveTerms,
                forbiddenTerms: forbiddenTerms
            ))
        }
    }

    @discardableResult
    private func runAction(_ success: String, action: () async throws -> Void) async -> Bool {
        guard canManageBrokerState else {
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
            return "Local daemon is not reachable. Open Diagnostic & Uninstall to install or repair it."
        }
        return description
    }

    private func localStateLoadError(_ error: Error) -> String {
        let description = String(describing: error)
        if isDaemonReachabilityError(error) {
            return "Daemon health check passed, but local state snapshot IPC failed after retrying. Restart or repair the local daemon. Last error: \(description)"
        }
        return "Local state could not be loaded: \(description)"
    }

    private func isDaemonReachabilityError(_ error: Error) -> Bool {
        let description = String(describing: error)
        return description.contains("socket(") || description.contains("connect:")
    }

    private func recoverFromStartupRaceIfPossible() async {
        errorMessage = nil
        try? await Task.sleep(for: .milliseconds(350))
        brokerStatus = await brokerController.status()
        guard brokerStatus.state == .healthy else {
            snapshot = nil
            return
        }
        do {
            try await loadSnapshotAfterHealthyStatus()
            errorMessage = nil
        } catch {
            snapshot = nil
            errorMessage = localStateLoadError(error)
        }
    }

    private func loadSnapshotAfterHealthyStatus() async throws {
        snapshot = try await loadSnapshotWithTransientRetry()
        if brokerStatus.state != .healthy {
            brokerStatus = await brokerController.status()
        }
        if selectedCLI == nil {
            selectedCLI = snapshot?.cliRegistrations.first?.name
        }
        maintainSelections()
    }

    private func loadSnapshotWithTransientRetry() async throws -> ControlPlaneSnapshot {
        var lastError: Error?
        let maxAttempts = Self.snapshotLoadRetryDelays.count + 1
        for attempt in 0..<maxAttempts {
            do {
                return try await client.loadSnapshot()
            } catch {
                guard isDaemonReachabilityError(error) else {
                    throw error
                }
                lastError = error
                guard attempt < Self.snapshotLoadRetryDelays.count else {
                    break
                }
                try? await Task.sleep(for: Self.snapshotLoadRetryDelays[attempt])
            }
        }
        throw lastError ?? StoreError.localStateSnapshotUnavailable
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

    private func isIgnored(_ update: AppUpdateRelease) -> Bool {
        guard !update.critical else { return false }
        return updateIgnoreDefaults.bool(forKey: ignoreKey(for: update))
    }

    private func ignoreKey(for update: AppUpdateRelease) -> String {
        "ignored-\(update.versionLabel)-\(update.htmlURL.absoluteString)"
    }

    private func maintainSelections() {
        if let selectedCLI, snapshot?.cliRegistrations.contains(where: { $0.name == selectedCLI }) != true {
            self.selectedCLI = snapshot?.cliRegistrations.first?.name
        }
        if selectedCLI == nil {
            selectedCLI = snapshot?.cliRegistrations.first?.name
        }
        if let selectedAPISessionProfile, !apiSessionProfiles.contains(where: { $0.name == selectedAPISessionProfile }) {
            self.selectedAPISessionProfile = apiSessionProfiles.first?.name
        }
        if selectedAPISessionProfile == nil {
            selectedAPISessionProfile = apiSessionProfiles.first?.name
        }
        if let oneTimeAPISession, !apiSessionProfiles.contains(where: { $0.name == oneTimeAPISession.profileName }) {
            self.oneTimeAPISession = nil
        }
        if let selectedMCPProfile, !mcpProfiles.contains(where: { $0.name == selectedMCPProfile }) {
            self.selectedMCPProfile = mcpProfiles.first?.name
        }
        if selectedMCPProfile == nil {
            selectedMCPProfile = mcpProfiles.first?.name
        }
        if let selectedBitwardenBinding, !bitwardenBindings.contains(where: { $0.alias == selectedBitwardenBinding }) {
            self.selectedBitwardenBinding = bitwardenBindings.first?.alias
        }
        if selectedBitwardenBinding == nil {
            selectedBitwardenBinding = bitwardenBindings.first?.alias
        }
        if let selectedAdapter, !policyPacks.contains(where: { $0.policyPackID == selectedAdapter }) {
            self.selectedAdapter = policyPacks.first?.policyPackID
        }
        if selectedAdapter == nil {
            selectedAdapter = policyPacks.first?.policyPackID
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

    enum StoreError: Error, CustomStringConvertible {
        case localStateSnapshotUnavailable

        var description: String {
            switch self {
            case .localStateSnapshotUnavailable:
                "Local state snapshot is unavailable."
            }
        }
    }
}
