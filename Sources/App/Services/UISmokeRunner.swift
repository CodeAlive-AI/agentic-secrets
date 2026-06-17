import AgenticFortressCore
import Darwin
import Foundation

enum UISmokeRunner {
    static func runAndExit() -> Never {
        Task { @MainActor in
            do {
                try await run()
                print("AgenticFortress UI smoke: ok")
                exit(0)
            } catch {
                fputs("AgenticFortress UI smoke failed: \(error)\n", stderr)
                exit(65)
            }
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    @MainActor
    private static func run() async throws {
        try await testEmptyState()
        try testRegisterWizardValidation()
        try await testDaemonUnavailableState()
        try await testDaemonInstallPlanState()
        try await testSelectionSurvivesRefresh()
        try await testMenuBarStatusReflectsDaemonHealth()
    }

    @MainActor
    private static func testEmptyState() async throws {
        let store = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [emptySnapshot()]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        await store.refresh()
        try expect(store.snapshot?.cliRegistrations.isEmpty == true, "empty state has no CLIs")
        try expect(store.filteredCLIRegistrations.isEmpty, "empty state filtered list is empty")
        try expect(store.selectedCLI == nil, "empty state does not invent selection")
    }

    private static func testRegisterWizardValidation() throws {
        let valid = [
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "synthetic-secret"),
            SecretDraft(environmentName: "TF_TOKEN", secretValue: "synthetic-secret-2")
        ]
        try expect(RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: valid), "valid register form submits")
        try expect(!RegisterCLIFormValidation.canSubmit(name: " ", targetPath: "/bin/echo", bindings: valid), "blank name is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "", bindings: valid), "blank target is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: [
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "one"),
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "two")
        ]), "duplicate env names are rejected")
        try expect(RegisterCLIFormValidation.environmentSecrets(valid)["HCLOUD_TOKEN"] == "synthetic-secret", "form builds env secret dictionary")
    }

    @MainActor
    private static func testDaemonUnavailableState() async throws {
        let store = ManagementStore(
            client: ThrowingAgenticFortressClient(),
            daemonController: StubDaemonStatusController(statusValue: unavailableDaemonStatus())
        )
        await store.refresh()
        try expect(store.daemonStatus.state == .unavailable, "daemon unavailable is surfaced")
        try expect(store.errorMessage != nil, "IPC failure shows an error")
        try expect(store.menuBarSummary == "Daemon unavailable", "menu bar summary reflects daemon failure")
    }

    @MainActor
    private static func testDaemonInstallPlanState() async throws {
        let plan = smokeInstallPlan(supported: true, missingExecutables: [])
        let installed = DaemonStatus(
            state: .unavailable,
            socketPath: plan.socketPath,
            launchAgentPath: plan.launchAgentPath,
            message: "Local daemon was installed. Open the installed app copy so the authenticated IPC manifest matches the running UI.",
            recoveryCommand: nil,
            checkedAt: Date()
        )
        let store = ManagementStore(
            client: ThrowingAgenticFortressClient(),
            daemonController: StubDaemonStatusController(
                statusValue: unavailableDaemonStatus(),
                installPlanValue: plan,
                installValue: installed
            )
        )
        await store.refresh()
        try expect(store.daemonInstallPlan?.canInstall == true, "supported install plan can install")
        await store.installOrRepairDaemon()
        try expect(store.daemonStatus.message.contains("Open the installed app"), "install result explains installed app handoff")

        let unsupported = ManagementStore(
            client: ThrowingAgenticFortressClient(),
            daemonController: StubDaemonStatusController(
                statusValue: unavailableDaemonStatus(),
                installPlanValue: smokeInstallPlan(supported: false, missingExecutables: ["agentic-fortressd-core"])
            )
        )
        await unsupported.refresh()
        try expect(unsupported.daemonInstallPlan?.canInstall == false, "missing helper blocks install action")
    }

    @MainActor
    private static func testSelectionSurvivesRefresh() async throws {
        let first = snapshot(cliNames: ["hcloud", "gh"])
        let second = snapshot(cliNames: ["hcloud", "gh", "terraform"])
        let store = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [first, second]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        await store.refresh()
        store.selectedSection = .cliSecrets
        store.selectedCLI = "gh"
        store.searchText = "g"
        await store.refresh()
        try expect(store.selectedSection == .cliSecrets, "sidebar section survives refresh")
        try expect(store.selectedCLI == "gh", "selected CLI survives refresh")
        try expect(store.selectedCLIRegistration?.name == "gh", "selected CLI resolves after refresh")
        try expect(store.searchText == "g", "search text survives refresh")
    }

    @MainActor
    private static func testMenuBarStatusReflectsDaemonHealth() async throws {
        let healthy = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [emptySnapshot()]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        await healthy.refresh()
        try expect(healthy.menuBarSummary == "Ok · 0 grants", "healthy menu summary includes health and grants")

        let broken = ManagementStore(
            client: ThrowingAgenticFortressClient(),
            daemonController: StubDaemonStatusController(statusValue: unavailableDaemonStatus())
        )
        await broken.refresh()
        try expect(broken.menuBarSymbol == "exclamationmark.triangle", "daemon failure uses attention menu symbol")

        let installing = ManagementStore(
            client: ThrowingAgenticFortressClient(),
            daemonController: StubDaemonStatusController(statusValue: unavailableDaemonStatus())
        )
        installing.daemonStatus = DaemonStatus(
            state: .installing,
            socketPath: "/tmp/agentic-fortress-ui-smoke.sock",
            launchAgentPath: "/tmp/com.agenticfortress.core.plist",
            message: "Installing local daemon...",
            recoveryCommand: nil,
            checkedAt: Date()
        )
        try expect(installing.menuBarSummary == "Installing daemon", "menu bar summary reflects install progress")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SmokeError.failed(message)
        }
    }

    private static func emptySnapshot() -> ManagementSnapshot {
        snapshot(cliNames: [])
    }

    private static func snapshot(cliNames: [String]) -> ManagementSnapshot {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return ManagementSnapshot(
            generatedAt: now,
            stateDirectory: "/tmp/agentic-fortress-ui-smoke",
            configPath: "/tmp/agentic-fortress-ui-smoke/config.json",
            cliRegistrations: cliNames.map { name in
                CLIRegistrationSummary(registration: CLIAppRegistration(
                    name: name,
                    targetPath: "/bin/echo",
                    targetResolvedPath: "/bin/echo",
                    targetIdentity: "sha256:" + shortDigest(name, length: 16),
                    targetCDHash: "cdhash-" + shortDigest(name, length: 8),
                    targetDesignatedRequirement: "identifier \"\(name)\"",
                    targetSigningIdentifier: "com.example.\(name)",
                    targetTeamIdentifier: nil,
                    environmentBindings: [CLIEnvironmentBinding(environmentName: "\(name.uppercased())_TOKEN", secretAlias: "\(name).token")],
                    registeredAt: now
                ), shimStatus: "installed")
            },
            secrets: [],
            proxyProfiles: [],
            mcpProfiles: [],
            bwsBindings: [],
            adapters: [],
            unlockGrants: [],
            auditEvents: [],
            securityHealth: SecurityHealthSummary(
                status: .ok,
                attentionItems: [],
                localSelfBuildReady: true,
                runtimeMajor: 26,
                requiredSDKMajor: 26
            )
        )
    }

    private static func healthyDaemonStatus() -> DaemonStatus {
        DaemonStatus(
            state: .healthy,
            socketPath: "/tmp/agentic-fortress-ui-smoke.sock",
            launchAgentPath: "/tmp/com.agenticfortress.core.plist",
            message: "Core daemon is reachable.",
            recoveryCommand: nil,
            checkedAt: Date()
        )
    }

    private static func unavailableDaemonStatus() -> DaemonStatus {
        DaemonStatus(
            state: .unavailable,
            socketPath: "/tmp/missing-agentic-fortress-ui-smoke.sock",
            launchAgentPath: "/tmp/com.agenticfortress.core.plist",
            message: "Core daemon is not reachable.",
            recoveryCommand: "scripts/install_local.sh --load",
            checkedAt: Date()
        )
    }

    private static func smokeInstallPlan(supported: Bool, missingExecutables: [String]) -> DaemonInstallPlan {
        DaemonInstallPlan(
            supported: supported,
            title: "Install Local Daemon",
            summary: supported ? "Install will copy this app bundle into the local self-build install prefix and start the core daemon." : "This app bundle is missing helper executables.",
            prefixPath: "/tmp/agentic-fortress-ui-smoke",
            appSourcePath: "/tmp/AgenticFortress.app",
            appDestinationPath: "/tmp/agentic-fortress-ui-smoke/Applications/AgenticFortress.app",
            binDirectoryPath: "/tmp/agentic-fortress-ui-smoke/bin",
            stateDirectoryPath: "/tmp/agentic-fortress-ui-smoke/var/agentic-fortress",
            runDirectoryPath: "/tmp/agentic-fortress-ui-smoke/run/agentic-fortress",
            launchAgentPath: "/tmp/agentic-fortress-ui-smoke/Library/LaunchAgents/com.agenticfortress.core.plist",
            manifestPath: "/tmp/agentic-fortress-ui-smoke/var/agentic-fortress/install-manifest.json",
            socketPath: "/tmp/agentic-fortress-ui-smoke/run/agentic-fortress/core.sock",
            commandPreview: "scripts/install_local.sh --load",
            missingExecutables: missingExecutables,
            currentAppIsInstalledCopy: false
        )
    }
}

private enum SmokeError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            message
        }
    }
}

private actor SequenceAgenticFortressClient: AgenticFortressClient {
    private var snapshots: [ManagementSnapshot]
    private var lastSnapshot: ManagementSnapshot

    init(snapshots: [ManagementSnapshot]) {
        self.snapshots = snapshots
        self.lastSnapshot = snapshots.last ?? UISmokeRunnerSnapshotFactory.empty()
    }

    func health() async throws {}

    func loadSnapshot() async throws -> ManagementSnapshot {
        if snapshots.isEmpty {
            return lastSnapshot
        }
        lastSnapshot = snapshots.removeFirst()
        return lastSnapshot
    }

    func registerCLI(_ request: ManagementCLIRegistrationRequest) async throws -> CLIRegistrationSummary {
        lastSnapshot.cliRegistrations.first!
    }

    func unregisterCLI(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary {
        lastSnapshot.cliRegistrations.first!
    }

    func refreshCLITrust(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary {
        lastSnapshot.cliRegistrations.first!
    }

    func replaceSecret(_ request: ManagementSecretReplacementRequest) async throws -> ManagedSecretSummary {
        ManagedSecretSummary(alias: request.alias, environment: request.environment, storeKind: "smoke", externalIDDigest: "sha256:smoke")
    }

    func deleteSecret(_ request: ManagementSecretDeletionRequest) async throws {}

    func upsertProxyProfile(_ profile: ProxyProfile) async throws -> ProxyProfileSummary {
        ProxyProfileSummary(profile: profile)
    }

    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary {
        MCPProfileSummary(profile: profile)
    }

    func createProxySession(_ request: ManagementProxySessionRequest) async throws -> ManagementProxySessionResponse {
        let profile = ProxyProfile(
            name: request.profileName,
            upstreamOrigin: URL(string: "https://api.example.com")!,
            allowedPathPrefixes: ["/"],
            allowedMethods: ["GET"],
            secretAlias: "smoke.secret"
        )
        let (session, token) = ProxyAuthorizer().createSession(profile: profile, bindPort: request.bindPort)
        return ManagementProxySessionResponse(session: session, oneTimeToken: token)
    }

    func clearUnlockGrants() async throws {}
    func exportRedactedAuditJSON() async throws -> String { "[]" }
}

private struct ThrowingAgenticFortressClient: AgenticFortressClient {
    func health() async throws {
        throw SmokeError.failed("daemon unavailable")
    }

    func loadSnapshot() async throws -> ManagementSnapshot {
        throw SmokeError.failed("daemon unavailable")
    }

    func registerCLI(_ request: ManagementCLIRegistrationRequest) async throws -> CLIRegistrationSummary { throw SmokeError.failed("unexpected register") }
    func unregisterCLI(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary { throw SmokeError.failed("unexpected unregister") }
    func refreshCLITrust(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary { throw SmokeError.failed("unexpected refresh trust") }
    func replaceSecret(_ request: ManagementSecretReplacementRequest) async throws -> ManagedSecretSummary { throw SmokeError.failed("unexpected replace") }
    func deleteSecret(_ request: ManagementSecretDeletionRequest) async throws { throw SmokeError.failed("unexpected delete") }
    func upsertProxyProfile(_ profile: ProxyProfile) async throws -> ProxyProfileSummary { throw SmokeError.failed("unexpected proxy") }
    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary { throw SmokeError.failed("unexpected mcp") }
    func createProxySession(_ request: ManagementProxySessionRequest) async throws -> ManagementProxySessionResponse { throw SmokeError.failed("unexpected proxy session") }
    func clearUnlockGrants() async throws { throw SmokeError.failed("unexpected grants") }
    func exportRedactedAuditJSON() async throws -> String { throw SmokeError.failed("unexpected audit") }
}

private enum UISmokeRunnerSnapshotFactory {
    static func empty() -> ManagementSnapshot {
        ManagementSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            stateDirectory: "/tmp/agentic-fortress-ui-smoke",
            configPath: "/tmp/agentic-fortress-ui-smoke/config.json",
            cliRegistrations: [],
            secrets: [],
            proxyProfiles: [],
            mcpProfiles: [],
            bwsBindings: [],
            adapters: [],
            unlockGrants: [],
            auditEvents: [],
            securityHealth: SecurityHealthSummary(
                status: .ok,
                attentionItems: [],
                localSelfBuildReady: true,
                runtimeMajor: 26,
                requiredSDKMajor: 26
            )
        )
    }
}
