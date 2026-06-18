import AgenticSecretsBroker
import AppKit
import Darwin
import Foundation
import SwiftUI

enum UISmokeRunner {
    static func runAndExit() -> Never {
        Task { @MainActor in
            do {
                try await run()
                print("Agentic Secrets UI smoke: ok")
                exit(0)
            } catch {
                fputs("Agentic Secrets UI smoke failed: \(error)\n", stderr)
                exit(65)
            }
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    @MainActor
    private static func run() async throws {
        try await testEmptyState()
        try await testSettingsLayout()
        try testRegisterWizardValidation()
        try testManagementEditorValidation()
        try testPasteboardCopy()
        try testCommandPolicyDraft()
        try testProviderDashboardLinks()
        try await testInvalidFormSubmitsStayLocal()
        try await testOriginNormalization()
        try await testDaemonUnavailableState()
        try await testUnavailableDaemonBlocksManagementActions()
        try await testBrokerInstallPlanState()
        try testManagedShellConfigurationCleanup()
        try await testContextActions()
        try await testManagementActions()
        try await testUpdateChecking()
        try testAuditRelatedItemRouting()
        try await testActivationRefreshLoadsMissingSnapshot()
        try await testSelectionSurvivesRefresh()
        try await testMenuBarStatusReflectsDaemonHealth()
    }

    @MainActor
    private static func testSettingsLayout() async throws {
        let store = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await store.refresh()
        try verifyHostingLayout(
            SettingsView(store: store),
            width: 920,
            height: 660,
            label: "settings window"
        )

        var terms = CommandPolicyTermDraft.from(
            destructiveTerms: CommandPolicyConfig.default.destructiveTerms,
            forbiddenTerms: CommandPolicyConfig.default.forbiddenTerms
        )
        var previewCommand = "hcloud server delete prod-db-01"
        let commandPolicy = CommandPolicySettingsPage(
            terms: Binding(
                get: { terms },
                set: { terms = $0 }
            ),
            previewCommand: Binding(
                get: { previewCommand },
                set: { previewCommand = $0 }
            ),
            hasChanges: false,
            canSave: true,
            isLoading: false,
            saveHelp: "Save command policy",
            revert: {},
            save: {}
        )

        try verifyHostingLayout(
            commandPolicy,
            width: 920,
            height: 660,
            label: "command policy settings"
        )
        try verifyHostingLayout(
            commandPolicy,
            width: 560,
            height: 660,
            label: "narrow command policy settings"
        )
        try verifyHostingLayout(
            APISessionProfileEditor(store: store),
            width: 520,
            height: 520,
            label: "simple API session profile sheet"
        )
        try verifyHostingLayout(
            MCPProfileEditor(store: store),
            width: 520,
            height: 460,
            label: "simple MCP profile sheet"
        )
        try verifyHostingLayout(
            BitwardenBindingEditor(store: store),
            width: 520,
            height: 460,
            label: "simple Bitwarden provider binding sheet"
        )
    }

    @MainActor
    private static func verifyHostingLayout<Content: View>(
        _ content: Content,
        width: CGFloat,
        height: CGFloat,
        label: String
    ) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        try expect(fittingSize.width.isFinite && fittingSize.height.isFinite, "\(label) reports finite fitting size")
        try expect(fittingSize.width > 0 && fittingSize.height > 0, "\(label) renders non-empty layout")
        try expect(fittingSize.width <= 1_400, "\(label) does not demand an oversized fixed width")
        try expect(fittingSize.height <= 2_400, "\(label) does not demand an oversized fixed height")
    }

    @MainActor
    private static func testEmptyState() async throws {
        let store = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await store.refresh()
        try expect(store.snapshot?.cliRegistrations.isEmpty == true, "empty state has no CLIs")
        try expect(store.filteredCLIRegistrations.isEmpty, "empty state filtered list is empty")
        try expect(store.selectedCLI == nil, "empty state does not invent selection")
    }

    private static func testRegisterWizardValidation() throws {
        try expect(RegisterCLIFormDefaults.installShim, "register CLI defaults to installing a command shim")
        try expect(
            ExecutablePathSelection.inferredCLIName(from: URL(fileURLWithPath: "/opt/homebrew/bin/hcloud")) == "hcloud",
            "register CLI infers a CLI name from the selected executable path"
        )
        try expect(ExecutablePathSelection.statusMessage(for: "/bin/echo") == nil, "known executable path passes target validation")
        try expect(ExecutablePathSelection.statusMessage(for: "bin/echo") != nil, "relative executable path is rejected")
        try expect(ExecutablePathSelection.statusMessage(for: "/definitely/missing/agentic-secrets-cli") != nil, "missing executable path is rejected")
        let valid = [
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "synthetic-secret"),
            SecretDraft(environmentName: "TF_TOKEN", secretValue: "synthetic-secret-2")
        ]
        try expect(RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: valid), "valid register form submits")
        try expect(!RegisterCLIFormValidation.canSubmit(name: " ", targetPath: "/bin/echo", bindings: valid), "blank name is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "", bindings: valid), "blank target is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "bin/echo", bindings: valid), "relative target path is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/definitely/missing/agentic-secrets-cli", bindings: valid), "missing target path is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: [
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "one"),
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "two")
        ]), "duplicate env names are rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: [
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "   ")
        ]), "whitespace-only secret values are rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: [
            SecretDraft(environmentName: "HCLOUD-TOKEN", secretValue: "synthetic-secret")
        ]), "hyphenated env names are rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: [
            SecretDraft(environmentName: "1TOKEN", secretValue: "synthetic-secret")
        ]), "env names starting with a digit are rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: [
            SecretDraft(environmentName: "TOKEN", secretValue: "one"),
            SecretDraft(environmentName: "token", secretValue: "two")
        ]), "case-insensitive duplicate env names are rejected")
        try expect(RegisterCLIFormValidation.isValidEnvironmentName("_TOKEN1"), "underscore-prefixed env name is accepted")
        try expect(RegisterCLIFormValidation.invalidEnvironmentNames([
            SecretDraft(environmentName: "GOOD_TOKEN", secretValue: "one"),
            SecretDraft(environmentName: "BAD TOKEN", secretValue: "two")
        ]) == ["BAD TOKEN"], "invalid env names are reported for inline guidance")
        try expect(RegisterCLIFormValidation.environmentSecrets(valid)["HCLOUD_TOKEN"] == "synthetic-secret", "form builds env secret dictionary")
        try expect(RegisterCLIFormValidation.environmentSecrets([
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "  synthetic-secret  ")
        ])["HCLOUD_TOKEN"] == "  synthetic-secret  ", "secret values are not trimmed while building payload")
        try expect(RegisterCLIFormValidation.environmentSecrets([
            SecretDraft(environmentName: "BAD-TOKEN", secretValue: "synthetic-secret")
        ]).isEmpty, "invalid env names are omitted from registration payload")
        try expect(RegisterCLIFormValidation.environmentSecrets([
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: " \n\t ")
        ]).isEmpty, "whitespace-only secret values are omitted from registration payload")
    }

    private static func testManagementEditorValidation() throws {
        try expect(APISessionProfileEditorDefaults.pathPrefixes == "/v1/", "proxy add flow has a safe default path prefix")
        try expect(APISessionProfileEditorDefaults.methods == "GET, POST", "proxy add flow has default HTTP methods")
        try expect(APISessionProfileEditorDefaults.tokenTTL == 900, "proxy add flow has a bounded default session TTL")
        try expect(
            ManagementEditorValidation.canSaveAPISessionProfile(
                name: "openai",
                origin: "api.openai.com",
                pathPrefixes: APISessionProfileEditorDefaults.pathPrefixes,
                methods: APISessionProfileEditorDefaults.methods,
                secretAlias: "ai.openai.dev"
            ),
            "API session editor accepts a simple profile using advanced defaults"
        )
        try expect(
            !ManagementEditorValidation.canSaveAPISessionProfile(
                name: " ",
                origin: "api.openai.com",
                pathPrefixes: "/v1/",
                methods: "GET",
                secretAlias: "ai.openai.dev"
            ),
            "API session editor rejects whitespace-only profile name"
        )
        try expect(
            !ManagementEditorValidation.canSaveAPISessionProfile(
                name: "openai",
                origin: "://",
                pathPrefixes: "/v1/",
                methods: "GET",
                secretAlias: "ai.openai.dev"
            ),
            "API session editor rejects malformed origin before submit"
        )
        try expect(
            ManagementEditorValidation.urlStatusMessage("://", field: "upstream origin") == "Enter a valid http or https URL for upstream origin.",
            "API session editor explains malformed origin inline"
        )
        try expect(
            !ManagementEditorValidation.canSaveAPISessionProfile(
                name: "openai",
                origin: "api.openai.com",
                pathPrefixes: " , ",
                methods: "GET",
                secretAlias: "ai.openai.dev"
            ),
            "API session editor rejects empty path prefix list"
        )
        try expect(
            ManagementEditorValidation.listStatusMessage(" , ", field: "allowed path prefix") == "Enter at least one allowed path prefix.",
            "API session editor explains empty path prefix list inline"
        )
        try expect(
            ManagementEditorValidation.pathPrefixStatusMessage("v1") == "Path prefixes must start with /.",
            "API session editor explains path prefixes that do not start with slash"
        )
        try expect(
            !ManagementEditorValidation.canSaveAPISessionProfile(
                name: "openai",
                origin: "api.openai.com",
                pathPrefixes: "/v1/",
                methods: " ",
                secretAlias: "ai.openai.dev"
            ),
            "API session editor rejects empty methods list"
        )
        try expect(
            !ManagementEditorValidation.canSaveAPISessionProfile(
                name: "openai",
                origin: "api.openai.com",
                pathPrefixes: "/v1/",
                methods: "GET POST",
                secretAlias: "ai.openai.dev"
            ),
            "API session editor rejects malformed HTTP method lists"
        )
        try expect(
            ManagementEditorValidation.httpMethodsStatusMessage("GET POST") == "Use comma-separated HTTP methods such as GET, POST, PATCH.",
            "API session editor explains malformed HTTP method lists inline"
        )
        try expect(MCPProfileEditorDefaults.authorizationHeader == "Authorization", "MCP add flow defaults to Authorization header")
        try expect(MCPProfileEditorDefaults.pathPrefixes == "/", "MCP add flow defaults to root path prefix")
        try expect(!MCPProfileEditorDefaults.allowCrossOriginRedirects, "MCP add flow blocks cross-origin redirects by default")
        try expect(
            ManagementEditorValidation.canSaveMCP(
                name: "linear",
                origin: "mcp.example.com",
                header: MCPProfileEditorDefaults.authorizationHeader,
                pathPrefixes: MCPProfileEditorDefaults.pathPrefixes
            ),
            "MCP editor accepts a simple profile using advanced defaults"
        )
        try expect(
            !ManagementEditorValidation.canSaveMCP(
                name: "linear",
                origin: " ",
                header: "Authorization",
                pathPrefixes: "/"
            ),
            "MCP editor rejects whitespace-only origin"
        )
        try expect(
            !ManagementEditorValidation.canSaveMCP(
                name: "linear",
                origin: "ftp://mcp.example.com",
                header: "Authorization",
                pathPrefixes: "/"
            ),
            "MCP editor rejects non-http origin before submit"
        )
        try expect(
            !ManagementEditorValidation.canSaveMCP(
                name: "linear",
                origin: "mcp.example.com",
                header: " ",
                pathPrefixes: "/"
            ),
            "MCP editor rejects whitespace-only authorization header"
        )
        try expect(
            !ManagementEditorValidation.canSaveMCP(
                name: "linear",
                origin: "mcp.example.com",
                header: "Authorization",
                pathPrefixes: " , "
            ),
            "MCP editor rejects empty path prefix list"
        )
        try expect(
            !ManagementEditorValidation.canSaveMCP(
                name: "linear",
                origin: "mcp.example.com",
                header: "Authorization",
                pathPrefixes: "mcp"
            ),
            "MCP editor rejects path prefixes that do not start with slash"
        )
        try expect(BitwardenBindingEditorDefaults.environment == ProviderEnvironment.dev.rawValue, "Bitwarden provider add flow defaults to development environment")
    }

    private static func testPasteboardCopy() throws {
        NSPasteboard.general.clearContents()
        try expect(PasteboardCopy.write("synthetic-copy-value"), "copy helper writes non-empty values")
        try expect(NSPasteboard.general.string(forType: .string) == "synthetic-copy-value", "copy helper updates pasteboard")
        try expect(!PasteboardCopy.write(""), "copy helper rejects empty values")
        try expect(NSPasteboard.general.string(forType: .string) == "synthetic-copy-value", "empty copy does not clear existing pasteboard value")
    }

    @MainActor
    private static func testDaemonUnavailableState() async throws {
        let store = ControlPlaneStore(
            client: ThrowingControlPlaneClient(),
            brokerController: StubBrokerStatusController(statusValue: unavailableBrokerStatus())
        )
        await store.refresh()
        try expect(store.brokerStatus.state == .unavailable, "daemon unavailable is surfaced")
        try expect(store.errorMessage == nil, "expected daemon unavailability does not show a raw alert")
        try expect(store.menuBarSummary == "Daemon unavailable", "menu bar summary reflects daemon failure")
        try expect(!store.brokerStatus.message.contains("socket("), "daemon status hides raw socket error")
        try expect(store.brokerStatus.detail != nil, "daemon status keeps technical detail for diagnostics")
        try expect(!store.canRegisterCLI, "CLI registration is unavailable until daemon is healthy")
        try expect(store.bestDaemonAction == .installOrRepair, "daemon unavailable state highlights install or repair as the next action")
        store.presentRegisterCLI()
        try expect(!store.showingRegisterCLI, "unavailable daemon does not open register CLI sheet")
        try expect(store.selectedSection == .diagnostics, "unavailable register action routes to diagnostics")
        store.presentAPISessionProfileEditor()
        try expect(!store.showingAPISessionProfileEditor, "unavailable daemon does not open proxy sheet")
        await store.registerCLI(
            name: "hcloud",
            targetPath: "/bin/echo",
            environmentSecrets: ["HCLOUD_TOKEN": "synthetic-secret"],
            installShim: false
        )
        try expect(!store.showingRegisterCLI, "unavailable daemon direct register submit stays closed")
        try expect(store.errorMessage == "Local daemon is not ready. Use Diagnostic & Uninstall to install or repair it.", "unavailable direct register submit shows repair guidance")
        CommandPolicyPackInstaller.presentOpenPanel(store: store)
        try expect(store.selectedSection == .diagnostics, "unavailable adapter install routes to diagnostics without opening a file picker")
    }

    @MainActor
    private static func testUnavailableDaemonBlocksManagementActions() async throws {
        let store = ControlPlaneStore(
            client: ThrowingControlPlaneClient(),
            brokerController: StubBrokerStatusController(statusValue: unavailableBrokerStatus())
        )
        await store.refresh()
        await store.replaceSecret(alias: "ai.openai.dev", value: "synthetic-secret", label: "OpenAI", environment: "api-session:openai")
        try expect(store.selectedSection == .diagnostics, "unavailable daemon action routes to diagnostics")
        try expect(store.errorMessage == "Local daemon is not ready. Use Diagnostic & Uninstall to install or repair it.", "unavailable daemon action shows clear repair guidance")

        let staleSnapshot = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await staleSnapshot.refresh()
        staleSnapshot.brokerStatus = unavailableBrokerStatus()
        try expect(!staleSnapshot.canExportAudit, "audit export is disabled when daemon becomes unavailable")
        try expect(!staleSnapshot.canClearUnlockGrants, "grant clearing is disabled when daemon becomes unavailable")
        let auditExported = await staleSnapshot.exportAudit()
        try expect(!auditExported, "audit export reports failure when daemon is unavailable")
        try expect(staleSnapshot.selectedSection == .diagnostics, "stale snapshot export routes to diagnostics when daemon is unavailable")
        let policySaved = await staleSnapshot.updateCommandPolicy(destructiveTerms: ["delete"], forbiddenTerms: ["shutdown"])
        try expect(!policySaved, "command policy save reports failure when daemon is unavailable")
        let trustRefreshed = await staleSnapshot.refreshTrust(for: "hcloud")
        try expect(!trustRefreshed, "trust refresh reports failure when daemon is unavailable")
        let secretDeleted = await staleSnapshot.deleteSecret(alias: "hcloud.token")
        try expect(!secretDeleted, "secret deletion reports failure when daemon is unavailable")
        let apiSessionDeleted = await staleSnapshot.deleteAPISessionProfile(name: "openai")
        try expect(!apiSessionDeleted, "proxy deletion reports failure when daemon is unavailable")
        let mcpDeleted = await staleSnapshot.deleteMCPProfile(name: "linear")
        try expect(!mcpDeleted, "MCP deletion reports failure when daemon is unavailable")
        let bwsDeleted = await staleSnapshot.deleteBitwardenBinding(alias: "cloud.hcloud.dev")
        try expect(!bwsDeleted, "Bitwarden provider deletion reports failure when daemon is unavailable")
        let adapterRevoked = await staleSnapshot.revokeAdapter(policyPackID: "com.example.policyPacks.demo")
        try expect(!adapterRevoked, "command policy pack revoke reports failure when daemon is unavailable")
        let sessionCreated = await staleSnapshot.createAPISession(profileName: "openai", bindPort: 48_177)
        try expect(!sessionCreated, "API session creation reports failure when daemon is unavailable")
        let grantsCleared = await staleSnapshot.clearDeliveryGrants()
        try expect(!grantsCleared, "grant clearing reports failure when daemon is unavailable")
    }

    private static func testCommandPolicyDraft() throws {
        let drafts = CommandPolicyTermDraft.from(
            destructiveTerms: [" Delete ", "remove", "shutdown"],
            forbiddenTerms: ["shutdown", "DESTROY"]
        )
        try expect(drafts == [
            CommandPolicyTermDraft(term: "delete", disposition: .destructive),
            CommandPolicyTermDraft(term: "remove", disposition: .destructive),
            CommandPolicyTermDraft(term: "destroy", disposition: .forbidden),
            CommandPolicyTermDraft(term: "shutdown", disposition: .forbidden)
        ], "command policy draft normalizes terms and lets forbidden override destructive")
        try expect(CommandPolicyTermDraft.destructiveTerms(from: drafts) == ["delete", "remove"], "command policy draft exports ask terms")
        try expect(CommandPolicyTermDraft.forbiddenTerms(from: drafts) == ["destroy", "shutdown"], "command policy draft exports block terms")
        let defaults = CommandPolicyTermDraft.from(
            destructiveTerms: CommandPolicyConfig.default.destructiveTerms,
            forbiddenTerms: CommandPolicyConfig.default.forbiddenTerms
        )
        try expect(CommandPolicyTermDraft.destructiveTerms(from: defaults) == ["delete", "destroy", "remove"], "default command policy asks for delete, destroy, and remove")
        try expect(CommandPolicyTermDraft.forbiddenTerms(from: defaults).isEmpty, "default command policy does not block commands")
        try expect(CommandPolicyTermValidator.normalized(" Delete ") == "delete", "command policy term input is normalized")
        try expect(CommandPolicyTermValidator.validate("", existing: []) == .empty, "blank policy term is rejected")
        try expect(CommandPolicyTermValidator.validate("delete", existing: ["delete"]) == .duplicate, "duplicate policy term is rejected")
        try expect(CommandPolicyTermValidator.validate("server-delete", existing: []) == .invalidCharacters, "separator policy term is rejected")
        try expect(CommandPolicyTermValidator.validate("destroy", existing: []) == .valid, "single policy term is accepted")
        try expect(CommandPolicyPreviewClassifier.classify(command: "hcloud server delete prod", destructiveTerms: ["delete"], forbiddenTerms: []) == .destructive("delete"), "destructive command preview requires fresh approval")
        try expect(CommandPolicyPreviewClassifier.classify(command: "hcloud server delete prod", destructiveTerms: ["delete"], forbiddenTerms: ["delete"]) == .forbidden("delete"), "forbidden command preview overrides destructive")
        try expect(CommandPolicyPreviewClassifier.classify(command: "hcloud server list", destructiveTerms: ["delete"], forbiddenTerms: []) == .standard, "read command preview stays standard")

        var settingsDraft = CommandPolicySettingsDraftState()
        let savedPolicy = CommandPolicySummary(config: CommandPolicyConfig(
            destructiveTerms: ["destroy"],
            forbiddenTerms: ["shutdown"]
        ))
        settingsDraft.sync(summary: savedPolicy, force: false)
        try expect(settingsDraft.hasLoadedBaseline, "command policy settings records first loaded baseline")
        try expect(CommandPolicyTermDraft.destructiveTerms(from: settingsDraft.terms) == ["destroy"], "command policy settings loads saved ask terms")
        try expect(CommandPolicyTermDraft.forbiddenTerms(from: settingsDraft.terms) == ["shutdown"], "command policy settings loads saved blocked terms")

        settingsDraft.terms.append(CommandPolicyTermDraft(term: "remove", disposition: .destructive))
        try expect(settingsDraft.hasChanges, "command policy settings detects unsaved local edits")
        let refreshedPolicy = CommandPolicySummary(config: CommandPolicyConfig(
            destructiveTerms: ["erase"],
            forbiddenTerms: ["nuke"]
        ))
        settingsDraft.sync(summary: refreshedPolicy, force: false)
        try expect(CommandPolicyTermDraft.destructiveTerms(from: settingsDraft.terms) == ["destroy", "remove"], "command policy settings refresh preserves unsaved edits")
        try expect(CommandPolicyTermDraft.forbiddenTerms(from: settingsDraft.terms) == ["shutdown"], "command policy settings refresh preserves blocked edits")
        settingsDraft.sync(summary: refreshedPolicy, force: true)
        try expect(CommandPolicyTermDraft.destructiveTerms(from: settingsDraft.terms) == ["erase"], "command policy settings force sync replaces ask terms")
        try expect(CommandPolicyTermDraft.forbiddenTerms(from: settingsDraft.terms) == ["nuke"], "command policy settings force sync replaces blocked terms")
    }

    private static func testProviderDashboardLinks() throws {
        let openAI = APISessionProfileSummary(profile: APISessionProfile(
            name: "custom-openai",
            upstreamOrigin: URL(string: "https://api.openai.com")!,
            allowedPathPrefixes: ["/v1/"],
            allowedMethods: ["GET"],
            secretAlias: "ai.openai.dev"
        ))
        try expect(
            ProviderDashboardResolver.link(for: openAI) == ProviderDashboardLink(title: "Open OpenAI Dashboard", url: URL(string: "https://platform.openai.com/api-keys")!),
            "OpenAI API session profile resolves to API key dashboard"
        )

        let anthropic = APISessionProfileSummary(profile: APISessionProfile(
            name: "anthropic",
            upstreamOrigin: URL(string: "https://example.invalid")!,
            allowedPathPrefixes: ["/v1/"],
            allowedMethods: ["POST"],
            secretAlias: "ai.anthropic.dev"
        ))
        try expect(
            ProviderDashboardResolver.link(for: anthropic) == ProviderDashboardLink(title: "Open Anthropic Console", url: URL(string: "https://console.anthropic.com/settings/keys")!),
            "Anthropic API session profile resolves to console key settings"
        )

        let custom = APISessionProfileSummary(profile: APISessionProfile(
            name: "internal",
            upstreamOrigin: URL(string: "https://proxy.example.invalid")!,
            allowedPathPrefixes: ["/"],
            allowedMethods: ["GET"],
            secretAlias: "internal.secret"
        ))
        try expect(ProviderDashboardResolver.link(for: custom) == nil, "custom API session profile does not invent a provider dashboard")
    }

    @MainActor
    private static func testInvalidFormSubmitsStayLocal() async throws {
        let store = ControlPlaneStore(
            client: ThrowingControlPlaneClient(),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await store.checkDaemon()
        let registered = await store.registerCLI(
            name: " ",
            targetPath: "/bin/echo",
            environmentSecrets: ["HCLOUD_TOKEN": "synthetic-secret"],
            installShim: false
        )
        try expect(!registered, "invalid direct register submit fails before IPC")
        try expect(store.errorMessage == "Enter CLI name before saving.", "invalid register submit shows field-specific guidance")

        let missingTargetRegistered = await store.registerCLI(
            name: "hcloud",
            targetPath: "/definitely/missing/agentic-secrets-cli",
            environmentSecrets: ["HCLOUD_TOKEN": "synthetic-secret"],
            installShim: false
        )
        try expect(!missingTargetRegistered, "missing executable direct register submit fails before IPC")
        try expect(store.errorMessage == "This path does not exist yet. Registration will fail until the executable is installed.", "missing executable register submit shows path guidance")

        let replaced = await store.replaceSecret(alias: "ai.openai.dev", value: "", label: "OpenAI", environment: "api-session:openai")
        try expect(!replaced, "empty secret replacement fails before IPC")
        try expect(store.errorMessage == "Enter secret value before saving.", "empty secret replacement shows guidance")

        let whitespaceReplaced = await store.replaceSecret(alias: "ai.openai.dev", value: " \n\t ", label: "OpenAI", environment: "api-session:openai")
        try expect(!whitespaceReplaced, "whitespace-only secret replacement fails before IPC")
        try expect(store.errorMessage == "Enter secret value before saving.", "whitespace-only secret replacement shows guidance")

        let apiSessionSaved = await store.upsertAPISessionProfile(name: "openai", origin: "://", pathPrefixes: "/v1/", methods: "GET", secretAlias: "ai.openai.dev", ttl: 900)
        try expect(!apiSessionSaved, "invalid API session URL fails before IPC")
        try expect(store.errorMessage == "Enter a valid http or https URL for upstream origin.", "invalid API session URL shows guidance")

        let invalidAPISessionPath = await store.upsertAPISessionProfile(name: "openai", origin: "api.openai.com", pathPrefixes: "v1", methods: "GET", secretAlias: "ai.openai.dev", ttl: 900)
        try expect(!invalidAPISessionPath, "invalid proxy path prefix fails before IPC")
        try expect(store.errorMessage == "Path prefixes must start with /.", "invalid proxy path prefix shows guidance")

        let invalidAPISessionMethod = await store.upsertAPISessionProfile(name: "openai", origin: "api.openai.com", pathPrefixes: "/v1/", methods: "GET POST", secretAlias: "ai.openai.dev", ttl: 900)
        try expect(!invalidAPISessionMethod, "invalid proxy method list fails before IPC")
        try expect(store.errorMessage == "Use comma-separated HTTP methods such as GET, POST, PATCH.", "invalid proxy method list shows guidance")

        let mcpSaved = await store.upsertMCP(name: "linear", origin: "https://mcp.example.com", header: "", pathPrefixes: "/", allowRedirects: false)
        try expect(!mcpSaved, "invalid MCP header fails before IPC")
        try expect(store.errorMessage == "Enter authorization header before saving.", "invalid MCP header shows guidance")

        let invalidMCPPath = await store.upsertMCP(name: "linear", origin: "https://mcp.example.com", header: "Authorization", pathPrefixes: "mcp", allowRedirects: false)
        try expect(!invalidMCPPath, "invalid MCP path prefix fails before IPC")
        try expect(store.errorMessage == "Path prefixes must start with /.", "invalid MCP path prefix shows guidance")

        let bwsSaved = await store.upsertBitwardenBinding(alias: "cloud.hcloud.dev", projectID: "project-dev", secretID: "secret-dev", environment: "qa")
        try expect(!bwsSaved, "invalid Bitwarden provider environment fails before IPC")
        try expect(store.errorMessage == "Choose a valid provider environment.", "invalid Bitwarden provider environment shows guidance")

        let sessionCreated = await store.createAPISession(profileName: "openai", bindPort: 70_000)
        try expect(!sessionCreated, "invalid API session port fails before IPC")
        try expect(store.errorMessage == "Choose a bind port between 1 and 65535.", "invalid API session port shows guidance")
    }

    @MainActor
    private static func testOriginNormalization() async throws {
        let store = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await store.refresh()

        let apiSessionSaved = await store.upsertAPISessionProfile(
            name: "openai",
            origin: "api.openai.com",
            pathPrefixes: "/v1/",
            methods: "GET, POST",
            secretAlias: "ai.openai.dev",
            ttl: 900
        )
        try expect(apiSessionSaved, "bare proxy host is normalized and saved")
        try expect(store.selectedAPISessionProfileSummary?.upstreamOrigin.absoluteString == "https://api.openai.com", "bare proxy host normalizes to https origin")

        let mcpSaved = await store.upsertMCP(
            name: "linear",
            origin: "mcp.example.com",
            header: "Authorization",
            pathPrefixes: "/",
            allowRedirects: false
        )
        try expect(mcpSaved, "bare MCP host is normalized and saved")
        try expect(store.selectedMCPProfileSummary?.origin.absoluteString == "https://mcp.example.com", "bare MCP host normalizes to https origin")
    }

    @MainActor
    private static func testBrokerInstallPlanState() async throws {
        let plan = smokeInstallPlan(supported: true, missingExecutables: [])
        try? FileManager.default.removeItem(atPath: plan.prefixPath)
        let installed = BrokerStatus(
            state: .unavailable,
            socketPath: plan.socketPath,
            launchAgentPath: plan.launchAgentPath,
            message: "Local daemon was installed. Open the installed copy so the authenticated IPC manifest matches the running UI.",
            detail: nil,
            recoveryCommand: nil,
            checkedAt: Date()
        )
        let store = ControlPlaneStore(
            client: ThrowingControlPlaneClient(),
            brokerController: StubBrokerStatusController(
                statusValue: unavailableBrokerStatus(),
                installPlanValue: plan,
                installValue: installed
            )
        )
        await store.refresh()
        try expect(store.brokerInstallPlan?.canInstall == true, "supported install plan can install")
        try expect(!store.canOpenInstalledApp, "installed app command is unavailable before the app copy exists")
        await store.installOrRepairDaemon()
        try FileManager.default.createDirectory(atPath: plan.appDestinationPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plan.prefixPath) }
        try expect(store.brokerStatus.message.contains("Open the installed copy"), "install result explains installed-copy handoff")
        try expect(store.bestDaemonAction == .openInstalledApp, "installed-copy handoff highlights open installed copy as the next action")
        try expect(store.canOpenInstalledApp, "installed app command becomes available when the app copy exists")
        try expect(InstalledAppOpener.installedAppURL(store: store)?.path == plan.appDestinationPath, "installed app opener resolves the same app copy path used by diagnostics and commands")

        let unsupported = ControlPlaneStore(
            client: ThrowingControlPlaneClient(),
            brokerController: StubBrokerStatusController(
                statusValue: unavailableBrokerStatus(),
                installPlanValue: smokeInstallPlan(supported: false, missingExecutables: ["agentic-secrets-brokerd"])
            )
        )
        await unsupported.refresh()
        try expect(unsupported.brokerInstallPlan?.canInstall == false, "missing helper blocks install action")

        let removable = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await removable.refresh()
        try expect(removable.brokerUninstallPlan?.canUninstall == true, "diagnostics exposes local uninstall plan")
        let removed = await removable.uninstallLocalInstall(purgeLocalState: true, removeShellConfiguration: true)
        try expect(removed, "successful uninstall reports completion to the UI")
        try expect(removable.brokerStatus.message.contains("install and state were removed"), "uninstall reports explicit state purge")
        try expect(removable.snapshot == nil, "uninstall clears loaded local state")

        let failedUninstall = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(
                statusValue: healthyBrokerStatus(),
                uninstallValue: BrokerStatus(
                    state: .healthy,
                    socketPath: "/tmp/agentic-secrets-ui-smoke/run/agentic-secrets/core.sock",
                    launchAgentPath: "/tmp/agentic-secrets-ui-smoke/Library/LaunchAgents/com.agenticsecrets.broker.plist",
                    message: "Uninstall failed: synthetic failure",
                    detail: nil,
                    recoveryCommand: nil,
                    checkedAt: Date()
                )
            )
        )
        await failedUninstall.refresh()
        let failed = await failedUninstall.uninstallLocalInstall(purgeLocalState: true, removeShellConfiguration: true)
        try expect(!failed, "failed uninstall is not treated as completion")
        try expect(failedUninstall.errorMessage == "Uninstall failed: synthetic failure", "failed uninstall keeps error feedback visible")
    }

    private static func testManagedShellConfigurationCleanup() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentic-secrets-shell-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shellConfig = root.appendingPathComponent(".zshrc")
        let binDir = root.appendingPathComponent("bin").path
        let shimDir = root.appendingPathComponent("shims").path
        let content = """
        export KEEP_THIS_PATH="/opt/example"

        # Agentic Secrets PATH
        case ":$PATH:" in
          *":\(binDir):"*) ;;
          *) export PATH="\(binDir):$PATH" ;;
        esac

        # AgenticSecrets CLI shims
        case ":$PATH:" in
          *":\(shimDir):"*) ;;
          *) export PATH="\(shimDir):$PATH" ;;
        esac

        # Other Tool PATH
        case ":$PATH:" in
          *":/opt/other-tool/bin:"*) ;;
          *) export PATH="/opt/other-tool/bin:$PATH" ;;
        esac
        """
        try Data(content.utf8).write(to: shellConfig)
        try ShellConfigurationCleaner.removeManagedBlocks(
            from: shellConfig,
            managedDirectories: [binDir, shimDir]
        )
        let cleaned = try String(contentsOf: shellConfig, encoding: .utf8)
        try expect(cleaned.contains("KEEP_THIS_PATH"), "shell cleanup preserves unrelated environment lines")
        try expect(cleaned.contains("Other Tool PATH"), "shell cleanup preserves unrelated PATH blocks")
        try expect(!cleaned.contains("# Agentic Secrets PATH"), "shell cleanup removes installer PATH block")
        try expect(!cleaned.contains("# AgenticSecrets CLI shims"), "shell cleanup removes shim PATH block")
        try expect(!cleaned.contains(binDir), "shell cleanup removes managed bin path")
        try expect(!cleaned.contains(shimDir), "shell cleanup removes managed shim path")
    }

    @MainActor
    private static func testContextActions() async throws {
        let store = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await store.refresh()
        try expect(store.canRegisterCLI, "register CLI action is available when daemon is healthy")
        try expect(store.canExportAudit, "audit export is available after snapshot load")
        store.presentAPISessionProfileEditor()
        try expect(store.selectedSection == .apiSessions, "API session editor action selects API sessions section")
        try expect(store.showingAPISessionProfileEditor, "API session editor action opens API session sheet")
        store.showingAPISessionProfileEditor = false
        store.presentMCPProfileEditor()
        try expect(store.selectedSection == .mcp, "MCP editor action selects MCP section")
        try expect(store.showingMCPProfileEditor, "MCP editor action opens MCP sheet")
        store.successMessage = "Saved"
        store.clearSuccessIfCurrent("Saved")
        try expect(store.successMessage == nil, "current success feedback can be auto-dismissed")
        store.successMessage = "Newer Saved"
        store.clearSuccessIfCurrent("Older Saved")
        try expect(store.successMessage == "Newer Saved", "stale success auto-dismiss does not clear newer feedback")
        store.errorMessage = "Needs attention"
        store.clearSuccessIfCurrent("Newer Saved")
        try expect(store.errorMessage == "Needs attention" && store.successMessage == "Newer Saved", "success auto-dismiss does not clear visible errors")
        store.clearFeedback()
        try expect(store.errorMessage == nil && store.successMessage == nil, "feedback can be dismissed")
    }

    @MainActor
    private static func testManagementActions() async throws {
        let base = snapshot(cliNames: ["hcloud"])
        var withResources = base
        withResources.apiSessionProfiles = [
            APISessionProfileSummary(profile: APISessionProfile(
                name: "openai",
                upstreamOrigin: URL(string: "https://api.openai.com")!,
                allowedPathPrefixes: ["/v1/"],
                allowedMethods: ["GET", "POST"],
                secretAlias: "ai.openai.dev"
            )),
            APISessionProfileSummary(profile: APISessionProfile(
                name: "anthropic",
                upstreamOrigin: URL(string: "https://api.anthropic.com")!,
                allowedPathPrefixes: ["/v1/"],
                allowedMethods: ["GET", "POST"],
                secretAlias: "ai.anthropic.dev"
            ))
        ]
        withResources.mcpProfiles = [
            MCPProfileSummary(profile: MCPUpstreamProfile(name: "linear", origin: URL(string: "https://mcp.example.com")!))
        ]
        withResources.bitwardenBindings = [
            BitwardenBindingSummary(
                binding: BitwardenSecretBinding(alias: "cloud.hcloud.dev", projectID: "project-dev", secretID: "secret-dev", environment: ProviderEnvironment.dev.rawValue),
                policy: BitwardenProviderLeasePolicy.policy(for: .dev)
            )
        ]
        let store = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [withResources, withResources, withResources, withResources, withResources]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await store.refresh()
        try expect(store.selectedAPISessionProfileSummary?.name == "openai", "proxy selection is initialized")
        try expect(store.selectedMCPProfileSummary?.name == "linear", "MCP selection is initialized")
        try expect(store.selectedBitwardenBindingSummary?.alias == "cloud.hcloud.dev", "Bitwarden provider binding selection is initialized")
        try expect(store.selectedPolicyPackSummary == nil, "fresh state does not invent a command policy pack selection")
        try expect(store.selectedCLIRegistration?.name == "hcloud", "CLI selection is initialized")

        let anchoredUnregisterStore = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [snapshot(cliNames: ["hcloud", "gh"])]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await anchoredUnregisterStore.refresh()
        anchoredUnregisterStore.selectedCLI = "hcloud"
        let unregisteredNamedCLI = await anchoredUnregisterStore.unregisterCLI(name: "gh", deleteSecretMaterial: false)
        try expect(unregisteredNamedCLI, "explicit CLI unregister succeeds")
        try expect(anchoredUnregisterStore.selectedCLI == "hcloud", "explicit CLI unregister preserves current selection when it differs")
        try expect(anchoredUnregisterStore.snapshot?.cliRegistrations.contains(where: { $0.name == "gh" }) == false, "explicit CLI unregister removes the confirmed CLI")

        await store.refreshTrust(for: "hcloud")
        try expect(store.successMessage == "Trust refreshed", "CLI trust refresh reports success")
        let secretDeleted = await store.deleteSecret(alias: "hcloud.token")
        try expect(secretDeleted, "secret deletion succeeds with healthy daemon")
        try expect(store.successMessage == "Secret deleted", "secret deletion reports success")
        await store.replaceSecret(alias: "ai.openai.dev", value: "synthetic-secret", label: "OpenAI", environment: "api-session:openai")
        try expect(store.successMessage == "Secret replaced", "API session secret replacement reports success")
        let sessionCreated = await store.createAPISession(profileName: "openai", bindPort: 48_177)
        try expect(sessionCreated, "valid API session succeeds")
        try expect(store.successMessage == "API session created", "API session creation reports success")
        try expect(store.selectedAPISession?.token.isEmpty == false, "API session exposes one-time token")
        try expect(store.selectedAPISession?.endpoint.scheme == "http", "API session endpoint uses local http")
        try expect(store.selectedAPISession?.endpoint.host == "127.0.0.1", "API session exposes localhost endpoint")
        try expect(store.selectedAPISession?.endpoint.port == 48_177, "API session exposes requested bind port")
        try expect(store.selectedAPISession?.endpoint.path.hasPrefix("/openai/session/") == true, "API session endpoint scopes token path to profile")
        store.selectedAPISessionProfile = "anthropic"
        try expect(store.selectedAPISession == nil, "API session one-time token is hidden when another profile is selected")
        store.selectedAPISessionProfile = "openai"
        try expect(store.selectedAPISession?.token.isEmpty == false, "API session one-time token returns only for its owning profile")
        store.clearAPISession(profileName: "anthropic")
        try expect(store.selectedAPISession?.token.isEmpty == false, "clearing another profile does not hide the selected proxy token")
        store.clearAPISession(profileName: "openai")
        try expect(store.selectedAPISession == nil, "API session one-time token can be explicitly hidden for its owning profile")
        let secondSessionCreated = await store.createAPISession(profileName: "openai", bindPort: 48_177)
        try expect(secondSessionCreated, "API session can be recreated after hiding one-time token")
        let apiSessionDeleted = await store.deleteAPISessionProfile(name: "openai")
        try expect(apiSessionDeleted, "API session profile delete reports success flag")
        try expect(store.successMessage == "API session profile deleted", "API session profile delete reports success")
        try expect(store.selectedAPISession == nil, "API session one-time token is cleared after deleting its profile")
        let mcpDeleted = await store.deleteMCPProfile(name: "linear")
        try expect(mcpDeleted, "MCP profile delete reports success flag")
        try expect(store.successMessage == "MCP profile deleted", "MCP profile delete reports success")
        await store.upsertBitwardenBinding(alias: "cloud.hcloud.prod", projectID: "project-prod", secretID: "secret-prod", environment: ProviderEnvironment.prod.rawValue)
        try expect(store.successMessage == "Bitwarden provider binding saved", "Bitwarden provider binding save reports success")
        let bwsDeleted = await store.deleteBitwardenBinding(alias: "cloud.hcloud.dev")
        try expect(bwsDeleted, "Bitwarden provider binding delete reports success flag")
        try expect(store.successMessage == "Bitwarden provider binding deleted", "Bitwarden provider binding delete reports success")
        let adapterRevoked = await store.revokeAdapter(policyPackID: "com.example.policyPacks.demo")
        try expect(adapterRevoked, "command policy pack revoke reports success flag")
        try expect(store.successMessage == "Command policy pack revoked", "command policy pack revoke reports success")
        let policySaved = await store.updateCommandPolicy(destructiveTerms: ["remove"], forbiddenTerms: ["shutdown"])
        try expect(policySaved, "command policy update reports success")
        try expect(store.successMessage == "Command policy saved", "command policy save reports success")
        await store.exportAudit()
        try expect(store.successMessage == "Audit loaded", "audit preview load reports success")
        try expect(store.exportedAudit == "[]", "audit preview stores redacted JSON")
        let exportPreview = await store.loadRedactedAuditForExport()
        try expect(exportPreview == "[]", "audit export loader returns redacted JSON")
        store.recordAuditExport(to: URL(fileURLWithPath: "/tmp/agentic-secrets-audit.json"))
        try expect(store.successMessage == "Audit exported to agentic-secrets-audit.json", "audit file export reports destination filename")
        store.recordExternalOpenFailure(label: "Provider Console", url: URL(string: "https://example.invalid/provider")!)
        try expect(store.errorMessage == "Could not open Provider Console. Copy this URL instead: https://example.invalid/provider", "external URL failures are recoverable with a copyable URL")
        try expect(LocalFileOpener.fileExists(atPath: "/bin/echo"), "local file opener accepts existing paths")
        store.recordLocalOpenFailure(label: "CLI executable", path: "/definitely/missing/agentic-secrets-cli")
        try expect(store.errorMessage == "Could not open CLI executable. Path is not available: /definitely/missing/agentic-secrets-cli", "local file open failures explain the missing path")
        await store.clearDeliveryGrants()
        try expect(store.successMessage == "All grants locked", "grant locking reports success")
        store.selectedCLI = "hcloud"
        await store.unregisterSelectedCLI(deleteSecretMaterial: true)
        try expect(store.successMessage == "CLI unregistered", "CLI unregister reports success")
        try expect(store.selectedCLI == nil, "CLI unregister clears selection")
    }

    @MainActor
    private static func testUpdateChecking() async throws {
        let latest = AppUpdateRelease(
            tagName: "v9.0.0",
            name: "Agentic Secrets 9.0.0",
            prerelease: false,
            htmlURL: URL(string: "https://github.com/CodeAlive-AI/agentic-secrets/releases/tag/v9.0.0")!,
            body: "Release notes\n\nMinimum macOS Version: 14.0"
        )
        let ignoredDefaultsSuite = "com.agenticsecrets.ui-smoke.updater.\(UUID().uuidString)"
        let ignoredDefaults = UserDefaults(suiteName: ignoredDefaultsSuite)!
        ignoredDefaults.removePersistentDomain(forName: ignoredDefaultsSuite)
        let store = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus()),
            updateChecker: StubAppUpdateChecker(update: latest),
            updateIgnoreDefaults: ignoredDefaults
        )
        await store.checkForUpdates(manual: true)
        try expect(store.availableUpdate == latest, "update checker stores available release")
        try expect(store.updateMenuTitle == "Update 9.0.0", "update menu title includes latest version")
        try expect(store.successMessage == "Agentic Secrets 9.0.0 is available", "manual update check reports available release")
        try verifyHostingLayout(
            ContentView(store: store),
            width: 1180,
            height: 760,
            label: "content view with update button"
        )
        store.ignoreAvailableUpdate()
        try expect(store.availableUpdate == nil, "noncritical update can be ignored")

        let critical = AppUpdateRelease(
            tagName: "v9.0.1",
            name: "Agentic Secrets 9.0.1",
            prerelease: false,
            htmlURL: URL(string: "https://github.com/CodeAlive-AI/agentic-secrets/releases/tag/v9.0.1")!,
            body: "Critical Security Update\n\nMinimum macOS Version: 14.0"
        )
        let criticalStore = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [emptySnapshot()]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus()),
            updateChecker: StubAppUpdateChecker(update: critical),
            updateIgnoreDefaults: ignoredDefaults
        )
        await criticalStore.checkForUpdates(manual: false)
        criticalStore.ignoreAvailableUpdate()
        try expect(criticalStore.availableUpdate == critical, "critical update cannot be ignored")

        let olderRunnable = AppUpdateRelease(
            tagName: "v2.0.0",
            name: "Agentic Secrets 2.0.0",
            prerelease: false,
            htmlURL: URL(string: "https://example.com/2")!,
            body: "Minimum macOS Version: 14.0"
        )
        let newerUnsupported = AppUpdateRelease(
            tagName: "v3.0.0",
            name: "Agentic Secrets 3.0.0",
            prerelease: false,
            htmlURL: URL(string: "https://example.com/3")!,
            body: "Minimum macOS Version: 99.0"
        )
        try expect(
            GitHubAppUpdateChecker.evaluate(
                releases: [olderRunnable, newerUnsupported],
                currentVersion: AppSemanticVersion("1.0.0"),
                osVersion: AppSemanticVersion("14.0.0")
            ) == olderRunnable,
            "update evaluation picks latest runnable release"
        )
    }

    private static func testAuditRelatedItemRouting() throws {
        var withResources = snapshot(cliNames: ["hcloud"])
        withResources.apiSessionProfiles = [
            APISessionProfileSummary(profile: APISessionProfile(
                name: "openai",
                upstreamOrigin: URL(string: "https://api.openai.com")!,
                allowedPathPrefixes: ["/v1/"],
                allowedMethods: ["GET"],
                secretAlias: "ai.openai.dev"
            ))
        ]
        withResources.mcpProfiles = [
            MCPProfileSummary(profile: MCPUpstreamProfile(name: "linear", origin: URL(string: "https://mcp.example.com")!))
        ]
        withResources.bitwardenBindings = [
            BitwardenBindingSummary(
                binding: BitwardenSecretBinding(alias: "cloud.hcloud.dev", projectID: "project-dev", secretID: "secret-dev", environment: ProviderEnvironment.dev.rawValue),
                policy: BitwardenProviderLeasePolicy.policy(for: .dev)
            )
        ]

        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .cliEnv, subjectID: "hcloud", secretID: "hcloud.token"), snapshot: withResources) == .cli("hcloud"), "audit CLI event routes to CLI registration")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .apiSession, subjectID: "missing", secretID: "ai.openai.dev"), snapshot: withResources) == .apiSession("openai"), "audit API session event routes by secret alias")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .bitwardenProvider, subjectID: "missing", secretID: "cloud.hcloud.dev"), snapshot: withResources) == .bitwardenBinding("cloud.hcloud.dev"), "audit Bitwarden provider event routes by binding alias")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .remoteMCP, subjectID: "linear", secretID: "mcp.linear"), snapshot: withResources) == .mcp("linear"), "audit MCP event routes to MCP profile")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .remoteSSHStdin, subjectID: "ssh", secretID: "ssh.key"), snapshot: withResources) == nil, "audit SSH event has no local route")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .apiSession, subjectID: "missing", secretID: "missing"), snapshot: withResources) == nil, "audit event without matching local item has no route")

        let cliEvent = auditEvent(flow: .cliEnv, subjectID: "hcloud", secretID: "hcloud.token")
        var apiSessionEvent = auditEvent(flow: .apiSession, subjectID: "openai", secretID: "ai.openai.dev")
        apiSessionEvent.time = Date(timeIntervalSince1970: cliEvent.time.timeIntervalSince1970 + 1)
        let allEvents = [cliEvent, apiSessionEvent]
        let visibleEvents = AuditEventFilter.filtered(allEvents, query: "openai")
        try expect(visibleEvents.map(\.id) == [apiSessionEvent.id], "audit filter limits visible events")
        try expect(
            AuditEventFilter.selectedVisibleEvent(selectedID: cliEvent.id, visibleEvents: visibleEvents) == nil,
            "hidden audit selection is not actionable after filtering"
        )
        try expect(
            AuditEventFilter.selectedVisibleEvent(selectedID: apiSessionEvent.id, visibleEvents: visibleEvents) == apiSessionEvent,
            "visible audit selection remains actionable after filtering"
        )
    }

    @MainActor
    private static func testActivationRefreshLoadsMissingSnapshot() async throws {
        let store = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [snapshot(cliNames: ["hcloud"])]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        try expect(store.snapshot == nil, "activation test starts without snapshot")
        await store.refreshAfterActivation()
        try expect(store.snapshot?.cliRegistrations.first?.name == "hcloud", "activation refresh loads missing snapshot")
        await store.refreshAfterActivation()
        try expect(store.brokerStatus.state == .healthy, "activation refresh keeps daemon status current after snapshot load")
    }

    @MainActor
    private static func testSelectionSurvivesRefresh() async throws {
        let first = snapshot(cliNames: ["hcloud", "gh"])
        let second = snapshot(cliNames: ["hcloud", "gh", "terraform"])
        let store = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [first, second]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
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
        try expect(store.usesToolbarSearch, "toolbar search is available on CLI section")
        store.selectedSection = .apiSessions
        try expect(!store.usesToolbarSearch, "toolbar search is hidden on sections that do not use the global query")
    }

    @MainActor
    private static func testMenuBarStatusReflectsDaemonHealth() async throws {
        var snapshotWithAudit = emptySnapshot()
        snapshotWithAudit.auditEvents = [
            auditEvent(flow: .cloudNativeIdentity, subjectID: "sensitive-subject", secretID: "secret-one"),
            auditEvent(flow: .apiSession, subjectID: "api-session-subject", secretID: "secret-two"),
            auditEvent(flow: .remoteMCP, subjectID: "mcp-subject", secretID: "secret-three"),
            auditEvent(flow: .bitwardenProvider, subjectID: "bws-subject", secretID: "secret-four")
        ]
        let healthy = ControlPlaneStore(
            client: SequenceControlPlaneClient(snapshots: [snapshotWithAudit]),
            brokerController: StubBrokerStatusController(statusValue: healthyBrokerStatus())
        )
        await healthy.refresh()
        try expect(healthy.menuBarSummary == "Ok · 0 grants", "healthy menu summary includes health and grants")
        try expect(healthy.canRegisterCLI, "CLI registration is available when daemon is healthy")
        try expect(healthy.menuBarRecentActivityTitles.count == 3, "menu bar recent activity is capped at three items")
        try expect(healthy.menuBarRecentActivityTitles.allSatisfy { $0.count <= 30 }, "menu bar recent activity labels stay short")
        try expect(!healthy.menuBarRecentActivityTitles.contains { $0.contains("secret") || $0.contains("subject") }, "menu bar recent activity does not expose subject or secret identifiers")

        let broken = ControlPlaneStore(
            client: ThrowingControlPlaneClient(),
            brokerController: StubBrokerStatusController(statusValue: unavailableBrokerStatus())
        )
        await broken.refresh()
        try expect(broken.menuBarSymbol == "exclamationmark.triangle", "daemon failure uses attention menu symbol")

        let installing = ControlPlaneStore(
            client: ThrowingControlPlaneClient(),
            brokerController: StubBrokerStatusController(statusValue: unavailableBrokerStatus())
        )
        installing.brokerStatus = BrokerStatus(
            state: .installing,
            socketPath: "/tmp/agentic-secrets-ui-smoke.sock",
            launchAgentPath: "/tmp/com.agenticsecrets.broker.plist",
            message: "Installing local daemon...",
            detail: nil,
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

    private static func emptySnapshot() -> ControlPlaneSnapshot {
        snapshot(cliNames: [])
    }

    private static func snapshot(cliNames: [String]) -> ControlPlaneSnapshot {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return ControlPlaneSnapshot(
            generatedAt: now,
            stateDirectory: "/tmp/agentic-secrets-ui-smoke",
            configPath: "/tmp/agentic-secrets-ui-smoke/config.json",
            cliRegistrations: cliNames.map { name in
                CLIRegistrationSummary(registration: CommandLineToolRegistration(
                    name: name,
                    targetPath: "/bin/echo",
                    targetResolvedPath: "/bin/echo",
                    targetIdentity: "sha256:" + shortDigest(name, length: 16),
                    targetCDHash: "cdhash-" + shortDigest(name, length: 8),
                    targetDesignatedRequirement: "identifier \"\(name)\"",
                    targetSigningIdentifier: "com.example.\(name)",
                    targetTeamIdentifier: nil,
                    environmentBindings: [EnvironmentSecretBinding(environmentName: "\(name.uppercased())_TOKEN", secretAlias: "\(name).token")],
                    registeredAt: now
                ), shimStatus: "installed")
            },
            secrets: [],
            apiSessionProfiles: [],
            mcpProfiles: [],
            bitwardenBindings: [],
            policyPacks: [],
            deliveryGrants: [],
            auditEvents: [],
            securityHealth: SecurityHealthSummary(
                status: .ok,
                attentionItems: [],
                localSelfBuildReady: true,
                runtimeMajor: 26,
                requiredSDKMajor: 26
            ),
            commandPolicy: CommandPolicySummary(config: .default)
        )
    }

    private static func auditEvent(flow: DeliveryChannel, subjectID: String, secretID: String) -> AuditEventSummary {
        AuditEventSummary(event: AuditEvent(
            event: "secret_delivery",
            decision: "allow",
            flow: flow,
            subjectID: subjectID,
            secretID: secretID,
            actionClass: "smoke.action",
            delivery: .env,
            policyEpoch: 1,
            approval: "once",
            outcome: "ok",
            time: Date(timeIntervalSince1970: 1_800_000_100)
        ))
    }

    private static func healthyBrokerStatus() -> BrokerStatus {
        BrokerStatus(
            state: .healthy,
            socketPath: "/tmp/agentic-secrets-ui-smoke.sock",
            launchAgentPath: "/tmp/com.agenticsecrets.broker.plist",
            message: "Broker daemon is reachable.",
            detail: nil,
            recoveryCommand: nil,
            checkedAt: Date()
        )
    }

    private static func unavailableBrokerStatus() -> BrokerStatus {
        BrokerStatus(
            state: .unavailable,
            socketPath: "/tmp/missing-agentic-secrets-ui-smoke.sock",
            launchAgentPath: "/tmp/com.agenticsecrets.broker.plist",
            message: "Local daemon is not installed yet.",
            detail: "socket(\"connect: No such file or directory\")",
            recoveryCommand: "scripts/install_local.sh --load",
            checkedAt: Date()
        )
    }

    private static func smokeInstallPlan(supported: Bool, missingExecutables: [String]) -> BrokerInstallPlan {
        BrokerInstallPlan(
            supported: supported,
            title: "Install Local Daemon",
            summary: supported ? "Install will copy this app bundle into the local self-build install prefix and start the broker daemon." : "This app bundle is missing helper executables.",
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

private actor SequenceControlPlaneClient: ControlPlaneClient {
    private var snapshots: [ControlPlaneSnapshot]
    private var lastSnapshot: ControlPlaneSnapshot

    init(snapshots: [ControlPlaneSnapshot]) {
        self.snapshots = snapshots
        self.lastSnapshot = snapshots.last ?? UISmokeRunnerSnapshotFactory.empty()
    }

    func health() async throws {}

    func loadSnapshot() async throws -> ControlPlaneSnapshot {
        if snapshots.isEmpty {
            return lastSnapshot
        }
        lastSnapshot = snapshots.removeFirst()
        return lastSnapshot
    }

    func registerCLI(_ request: ControlPlaneCommandLineToolRegistrationRequest) async throws -> CLIRegistrationSummary {
        lastSnapshot.cliRegistrations.first!
    }

    func unregisterCLI(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary {
        guard let removed = lastSnapshot.cliRegistrations.first(where: { $0.name == request.name }) ?? lastSnapshot.cliRegistrations.first else {
            throw SmokeError.failed("missing CLI for unregister")
        }
        lastSnapshot.cliRegistrations.removeAll { $0.name == removed.name }
        snapshots.removeAll { snapshot in
            snapshot.cliRegistrations.contains(where: { $0.name == removed.name })
        }
        return removed
    }

    func refreshCLITrust(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary {
        lastSnapshot.cliRegistrations.first!
    }

    func replaceSecret(_ request: ControlPlaneSecretReplacementRequest) async throws -> ManagedSecretSummary {
        ManagedSecretSummary(alias: request.alias, environment: request.environment, storeKind: "smoke", externalIDDigest: "sha256:smoke")
    }

    func deleteSecret(_ request: ControlPlaneSecretDeletionRequest) async throws {}

    func upsertAPISessionProfile(_ profile: APISessionProfile) async throws -> APISessionProfileSummary {
        let summary = APISessionProfileSummary(profile: profile)
        lastSnapshot.apiSessionProfiles.removeAll { $0.name == summary.name }
        lastSnapshot.apiSessionProfiles.append(summary)
        lastSnapshot.apiSessionProfiles.sort { $0.name < $1.name }
        snapshots.removeAll()
        return summary
    }

    func deleteAPISessionProfile(_ request: ControlPlaneNameRequest) async throws {}

    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary {
        let summary = MCPProfileSummary(profile: profile)
        lastSnapshot.mcpProfiles.removeAll { $0.name == summary.name }
        lastSnapshot.mcpProfiles.append(summary)
        lastSnapshot.mcpProfiles.sort { $0.name < $1.name }
        snapshots.removeAll()
        return summary
    }

    func deleteMCPProfile(_ request: ControlPlaneNameRequest) async throws {}

    func upsertBitwardenBinding(_ binding: BitwardenSecretBinding) async throws -> BitwardenBindingSummary {
        BitwardenBindingSummary(binding: binding, policy: BitwardenProviderLeasePolicy.policy(for: ProviderEnvironment(rawValue: binding.environment) ?? .dev))
    }

    func deleteBitwardenBinding(_ request: ControlPlaneNameRequest) async throws {}

    func installAdapter(_ payload: CommandPolicyPackPayload) async throws -> PolicyPackSummary {
        PolicyPackSummary(payload: payload, policyPackHash: AdapterCanonicalizer.hash(payload), installedAt: Date())
    }

    func revokeAdapter(_ request: ControlPlaneNameRequest) async throws {}

    func updateCommandPolicy(_ request: ControlPlaneCommandPolicyUpdateRequest) async throws -> CommandPolicySummary {
        CommandPolicySummary(config: request.config)
    }

    func createAPISession(_ request: ControlPlaneAPISessionRequest) async throws -> ControlPlaneAPISessionResponse {
        let profile = APISessionProfile(
            name: request.profileName,
            upstreamOrigin: URL(string: "https://api.example.com")!,
            allowedPathPrefixes: ["/"],
            allowedMethods: ["GET"],
            secretAlias: "smoke.secret"
        )
        let (session, token) = APISessionAuthorizer().createSession(profile: profile, bindPort: request.bindPort)
        return ControlPlaneAPISessionResponse(session: session, oneTimeToken: token)
    }

    func clearDeliveryGrants() async throws {}
    func exportRedactedAuditJSON() async throws -> String { "[]" }
}

private struct ThrowingControlPlaneClient: ControlPlaneClient {
    func health() async throws {
        throw SmokeError.failed("daemon unavailable")
    }

    func loadSnapshot() async throws -> ControlPlaneSnapshot {
        throw SmokeError.failed("daemon unavailable")
    }

    func registerCLI(_ request: ControlPlaneCommandLineToolRegistrationRequest) async throws -> CLIRegistrationSummary { throw SmokeError.failed("unexpected register") }
    func unregisterCLI(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary { throw SmokeError.failed("unexpected unregister") }
    func refreshCLITrust(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary { throw SmokeError.failed("unexpected refresh trust") }
    func replaceSecret(_ request: ControlPlaneSecretReplacementRequest) async throws -> ManagedSecretSummary { throw SmokeError.failed("unexpected replace") }
    func deleteSecret(_ request: ControlPlaneSecretDeletionRequest) async throws { throw SmokeError.failed("unexpected delete") }
    func upsertAPISessionProfile(_ profile: APISessionProfile) async throws -> APISessionProfileSummary { throw SmokeError.failed("unexpected proxy") }
    func deleteAPISessionProfile(_ request: ControlPlaneNameRequest) async throws { throw SmokeError.failed("unexpected proxy delete") }
    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary { throw SmokeError.failed("unexpected mcp") }
    func deleteMCPProfile(_ request: ControlPlaneNameRequest) async throws { throw SmokeError.failed("unexpected mcp delete") }
    func upsertBitwardenBinding(_ binding: BitwardenSecretBinding) async throws -> BitwardenBindingSummary { throw SmokeError.failed("unexpected bws") }
    func deleteBitwardenBinding(_ request: ControlPlaneNameRequest) async throws { throw SmokeError.failed("unexpected bws delete") }
    func installAdapter(_ payload: CommandPolicyPackPayload) async throws -> PolicyPackSummary { throw SmokeError.failed("unexpected adapter install") }
    func revokeAdapter(_ request: ControlPlaneNameRequest) async throws { throw SmokeError.failed("unexpected command policy pack revoke") }
    func updateCommandPolicy(_ request: ControlPlaneCommandPolicyUpdateRequest) async throws -> CommandPolicySummary { CommandPolicySummary(config: request.config) }
    func createAPISession(_ request: ControlPlaneAPISessionRequest) async throws -> ControlPlaneAPISessionResponse { throw SmokeError.failed("unexpected API session") }
    func clearDeliveryGrants() async throws { throw SmokeError.failed("unexpected grants") }
    func exportRedactedAuditJSON() async throws -> String { throw SmokeError.failed("unexpected audit") }
}

private struct StubAppUpdateChecker: AppUpdateChecking {
    var update: AppUpdateRelease?

    func availableUpdate(
        currentVersion: String,
        osVersion: OperatingSystemVersion
    ) async throws -> AppUpdateRelease? {
        update
    }
}

private enum UISmokeRunnerSnapshotFactory {
    static func empty() -> ControlPlaneSnapshot {
        ControlPlaneSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            stateDirectory: "/tmp/agentic-secrets-ui-smoke",
            configPath: "/tmp/agentic-secrets-ui-smoke/config.json",
            cliRegistrations: [],
            secrets: [],
            apiSessionProfiles: [],
            mcpProfiles: [],
            bitwardenBindings: [],
            policyPacks: [],
            deliveryGrants: [],
            auditEvents: [],
            securityHealth: SecurityHealthSummary(
                status: .ok,
                attentionItems: [],
                localSelfBuildReady: true,
                runtimeMajor: 26,
                requiredSDKMajor: 26
            ),
            commandPolicy: CommandPolicySummary(config: .default)
        )
    }
}
