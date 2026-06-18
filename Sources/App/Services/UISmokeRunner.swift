import AgenticFortressCore
import AppKit
import Darwin
import Foundation
import SwiftUI

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
        try await testDaemonInstallPlanState()
        try await testContextActions()
        try await testManagementActions()
        try testAuditRelatedItemRouting()
        try await testActivationRefreshLoadsMissingSnapshot()
        try await testSelectionSurvivesRefresh()
        try await testMenuBarStatusReflectsDaemonHealth()
    }

    @MainActor
    private static func testSettingsLayout() async throws {
        let store = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [emptySnapshot()]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
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
            ProxyProfileEditor(store: store),
            width: 520,
            height: 520,
            label: "simple proxy profile sheet"
        )
        try verifyHostingLayout(
            MCPProfileEditor(store: store),
            width: 520,
            height: 460,
            label: "simple MCP profile sheet"
        )
        try verifyHostingLayout(
            BWSBindingEditor(store: store),
            width: 520,
            height: 460,
            label: "simple BWS binding sheet"
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
        try expect(RegisterCLIFormDefaults.installShim, "register CLI defaults to installing a command shim")
        try expect(
            ExecutablePathSelection.inferredCLIName(from: URL(fileURLWithPath: "/opt/homebrew/bin/hcloud")) == "hcloud",
            "register CLI infers a CLI name from the selected executable path"
        )
        try expect(ExecutablePathSelection.statusMessage(for: "/bin/echo") == nil, "known executable path passes target validation")
        try expect(ExecutablePathSelection.statusMessage(for: "bin/echo") != nil, "relative executable path is rejected")
        try expect(ExecutablePathSelection.statusMessage(for: "/definitely/missing/agentic-fortress-cli") != nil, "missing executable path is rejected")
        let valid = [
            SecretDraft(environmentName: "HCLOUD_TOKEN", secretValue: "synthetic-secret"),
            SecretDraft(environmentName: "TF_TOKEN", secretValue: "synthetic-secret-2")
        ]
        try expect(RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/bin/echo", bindings: valid), "valid register form submits")
        try expect(!RegisterCLIFormValidation.canSubmit(name: " ", targetPath: "/bin/echo", bindings: valid), "blank name is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "", bindings: valid), "blank target is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "bin/echo", bindings: valid), "relative target path is rejected")
        try expect(!RegisterCLIFormValidation.canSubmit(name: "hcloud", targetPath: "/definitely/missing/agentic-fortress-cli", bindings: valid), "missing target path is rejected")
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
        try expect(ProxyProfileEditorDefaults.pathPrefixes == "/v1/", "proxy add flow has a safe default path prefix")
        try expect(ProxyProfileEditorDefaults.methods == "GET, POST", "proxy add flow has default HTTP methods")
        try expect(ProxyProfileEditorDefaults.tokenTTL == 900, "proxy add flow has a bounded default session TTL")
        try expect(
            ManagementEditorValidation.canSaveProxy(
                name: "openai",
                origin: "api.openai.com",
                pathPrefixes: ProxyProfileEditorDefaults.pathPrefixes,
                methods: ProxyProfileEditorDefaults.methods,
                secretAlias: "ai.openai.dev"
            ),
            "proxy editor accepts a simple profile using advanced defaults"
        )
        try expect(
            !ManagementEditorValidation.canSaveProxy(
                name: " ",
                origin: "api.openai.com",
                pathPrefixes: "/v1/",
                methods: "GET",
                secretAlias: "ai.openai.dev"
            ),
            "proxy editor rejects whitespace-only profile name"
        )
        try expect(
            !ManagementEditorValidation.canSaveProxy(
                name: "openai",
                origin: "://",
                pathPrefixes: "/v1/",
                methods: "GET",
                secretAlias: "ai.openai.dev"
            ),
            "proxy editor rejects malformed origin before submit"
        )
        try expect(
            ManagementEditorValidation.urlStatusMessage("://", field: "upstream origin") == "Enter a valid http or https URL for upstream origin.",
            "proxy editor explains malformed origin inline"
        )
        try expect(
            !ManagementEditorValidation.canSaveProxy(
                name: "openai",
                origin: "api.openai.com",
                pathPrefixes: " , ",
                methods: "GET",
                secretAlias: "ai.openai.dev"
            ),
            "proxy editor rejects empty path prefix list"
        )
        try expect(
            ManagementEditorValidation.listStatusMessage(" , ", field: "allowed path prefix") == "Enter at least one allowed path prefix.",
            "proxy editor explains empty path prefix list inline"
        )
        try expect(
            ManagementEditorValidation.pathPrefixStatusMessage("v1") == "Path prefixes must start with /.",
            "proxy editor explains path prefixes that do not start with slash"
        )
        try expect(
            !ManagementEditorValidation.canSaveProxy(
                name: "openai",
                origin: "api.openai.com",
                pathPrefixes: "/v1/",
                methods: " ",
                secretAlias: "ai.openai.dev"
            ),
            "proxy editor rejects empty methods list"
        )
        try expect(
            !ManagementEditorValidation.canSaveProxy(
                name: "openai",
                origin: "api.openai.com",
                pathPrefixes: "/v1/",
                methods: "GET POST",
                secretAlias: "ai.openai.dev"
            ),
            "proxy editor rejects malformed HTTP method lists"
        )
        try expect(
            ManagementEditorValidation.httpMethodsStatusMessage("GET POST") == "Use comma-separated HTTP methods such as GET, POST, PATCH.",
            "proxy editor explains malformed HTTP method lists inline"
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
        try expect(BWSBindingEditorDefaults.environment == ProviderEnvironment.dev.rawValue, "BWS add flow defaults to development environment")
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
        let store = ManagementStore(
            client: ThrowingAgenticFortressClient(),
            daemonController: StubDaemonStatusController(statusValue: unavailableDaemonStatus())
        )
        await store.refresh()
        try expect(store.daemonStatus.state == .unavailable, "daemon unavailable is surfaced")
        try expect(store.errorMessage == nil, "expected daemon unavailability does not show a raw alert")
        try expect(store.menuBarSummary == "Daemon unavailable", "menu bar summary reflects daemon failure")
        try expect(!store.daemonStatus.message.contains("socket("), "daemon status hides raw socket error")
        try expect(store.daemonStatus.detail != nil, "daemon status keeps technical detail for diagnostics")
        try expect(!store.canRegisterCLI, "CLI registration is unavailable until daemon is healthy")
        try expect(store.bestDaemonAction == .installOrRepair, "daemon unavailable state highlights install or repair as the next action")
        store.presentRegisterCLI()
        try expect(!store.showingRegisterCLI, "unavailable daemon does not open register CLI sheet")
        try expect(store.selectedSection == .diagnostics, "unavailable register action routes to diagnostics")
        store.presentProxyProfileEditor()
        try expect(!store.showingProxyProfileEditor, "unavailable daemon does not open proxy sheet")
        await store.registerCLI(
            name: "hcloud",
            targetPath: "/bin/echo",
            environmentSecrets: ["HCLOUD_TOKEN": "synthetic-secret"],
            installShim: false
        )
        try expect(!store.showingRegisterCLI, "unavailable daemon direct register submit stays closed")
        try expect(store.errorMessage == "Local daemon is not ready. Use Diagnostics to install or repair it.", "unavailable direct register submit shows repair guidance")
        AdapterPackInstaller.presentOpenPanel(store: store)
        try expect(store.selectedSection == .diagnostics, "unavailable adapter install routes to diagnostics without opening a file picker")
    }

    @MainActor
    private static func testUnavailableDaemonBlocksManagementActions() async throws {
        let store = ManagementStore(
            client: ThrowingAgenticFortressClient(),
            daemonController: StubDaemonStatusController(statusValue: unavailableDaemonStatus())
        )
        await store.refresh()
        await store.replaceSecret(alias: "ai.openai.dev", value: "synthetic-secret", label: "OpenAI", environment: "proxy:openai")
        try expect(store.selectedSection == .diagnostics, "unavailable daemon action routes to diagnostics")
        try expect(store.errorMessage == "Local daemon is not ready. Use Diagnostics to install or repair it.", "unavailable daemon action shows clear repair guidance")

        let staleSnapshot = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [emptySnapshot()]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        await staleSnapshot.refresh()
        staleSnapshot.daemonStatus = unavailableDaemonStatus()
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
        let proxyDeleted = await staleSnapshot.deleteProxyProfile(name: "openai")
        try expect(!proxyDeleted, "proxy deletion reports failure when daemon is unavailable")
        let mcpDeleted = await staleSnapshot.deleteMCPProfile(name: "linear")
        try expect(!mcpDeleted, "MCP deletion reports failure when daemon is unavailable")
        let bwsDeleted = await staleSnapshot.deleteBWSBinding(alias: "cloud.hcloud.dev")
        try expect(!bwsDeleted, "BWS deletion reports failure when daemon is unavailable")
        let adapterRevoked = await staleSnapshot.revokeAdapter(adapterID: BuiltInAdapterPacks.hcloud.adapterID)
        try expect(!adapterRevoked, "adapter revoke reports failure when daemon is unavailable")
        let sessionCreated = await staleSnapshot.createProxySession(profileName: "openai", bindPort: 48_177)
        try expect(!sessionCreated, "proxy session creation reports failure when daemon is unavailable")
        let grantsCleared = await staleSnapshot.clearUnlockGrants()
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
        try expect(CommandPolicyTermDraft.destructiveTerms(from: defaults) == ["delete", "remove"], "default command policy asks for delete and remove")
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
        let openAI = ProxyProfileSummary(profile: ProxyProfile(
            name: "custom-openai",
            upstreamOrigin: URL(string: "https://api.openai.com")!,
            allowedPathPrefixes: ["/v1/"],
            allowedMethods: ["GET"],
            secretAlias: "ai.openai.dev"
        ))
        try expect(
            ProviderDashboardResolver.link(for: openAI) == ProviderDashboardLink(title: "Open OpenAI Dashboard", url: URL(string: "https://platform.openai.com/api-keys")!),
            "OpenAI proxy profile resolves to API key dashboard"
        )

        let anthropic = ProxyProfileSummary(profile: ProxyProfile(
            name: "anthropic",
            upstreamOrigin: URL(string: "https://example.invalid")!,
            allowedPathPrefixes: ["/v1/"],
            allowedMethods: ["POST"],
            secretAlias: "ai.anthropic.dev"
        ))
        try expect(
            ProviderDashboardResolver.link(for: anthropic) == ProviderDashboardLink(title: "Open Anthropic Console", url: URL(string: "https://console.anthropic.com/settings/keys")!),
            "Anthropic proxy profile resolves to console key settings"
        )

        let custom = ProxyProfileSummary(profile: ProxyProfile(
            name: "internal",
            upstreamOrigin: URL(string: "https://proxy.example.invalid")!,
            allowedPathPrefixes: ["/"],
            allowedMethods: ["GET"],
            secretAlias: "internal.secret"
        ))
        try expect(ProviderDashboardResolver.link(for: custom) == nil, "custom proxy profile does not invent a provider dashboard")
    }

    @MainActor
    private static func testInvalidFormSubmitsStayLocal() async throws {
        let store = ManagementStore(
            client: ThrowingAgenticFortressClient(),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
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
            targetPath: "/definitely/missing/agentic-fortress-cli",
            environmentSecrets: ["HCLOUD_TOKEN": "synthetic-secret"],
            installShim: false
        )
        try expect(!missingTargetRegistered, "missing executable direct register submit fails before IPC")
        try expect(store.errorMessage == "This path does not exist yet. Registration will fail until the executable is installed.", "missing executable register submit shows path guidance")

        let replaced = await store.replaceSecret(alias: "ai.openai.dev", value: "", label: "OpenAI", environment: "proxy:openai")
        try expect(!replaced, "empty secret replacement fails before IPC")
        try expect(store.errorMessage == "Enter secret value before saving.", "empty secret replacement shows guidance")

        let whitespaceReplaced = await store.replaceSecret(alias: "ai.openai.dev", value: " \n\t ", label: "OpenAI", environment: "proxy:openai")
        try expect(!whitespaceReplaced, "whitespace-only secret replacement fails before IPC")
        try expect(store.errorMessage == "Enter secret value before saving.", "whitespace-only secret replacement shows guidance")

        let proxySaved = await store.upsertProxy(name: "openai", origin: "://", pathPrefixes: "/v1/", methods: "GET", secretAlias: "ai.openai.dev", ttl: 900)
        try expect(!proxySaved, "invalid proxy URL fails before IPC")
        try expect(store.errorMessage == "Enter a valid http or https URL for upstream origin.", "invalid proxy URL shows guidance")

        let invalidProxyPath = await store.upsertProxy(name: "openai", origin: "api.openai.com", pathPrefixes: "v1", methods: "GET", secretAlias: "ai.openai.dev", ttl: 900)
        try expect(!invalidProxyPath, "invalid proxy path prefix fails before IPC")
        try expect(store.errorMessage == "Path prefixes must start with /.", "invalid proxy path prefix shows guidance")

        let invalidProxyMethod = await store.upsertProxy(name: "openai", origin: "api.openai.com", pathPrefixes: "/v1/", methods: "GET POST", secretAlias: "ai.openai.dev", ttl: 900)
        try expect(!invalidProxyMethod, "invalid proxy method list fails before IPC")
        try expect(store.errorMessage == "Use comma-separated HTTP methods such as GET, POST, PATCH.", "invalid proxy method list shows guidance")

        let mcpSaved = await store.upsertMCP(name: "linear", origin: "https://mcp.example.com", header: "", pathPrefixes: "/", allowRedirects: false)
        try expect(!mcpSaved, "invalid MCP header fails before IPC")
        try expect(store.errorMessage == "Enter authorization header before saving.", "invalid MCP header shows guidance")

        let invalidMCPPath = await store.upsertMCP(name: "linear", origin: "https://mcp.example.com", header: "Authorization", pathPrefixes: "mcp", allowRedirects: false)
        try expect(!invalidMCPPath, "invalid MCP path prefix fails before IPC")
        try expect(store.errorMessage == "Path prefixes must start with /.", "invalid MCP path prefix shows guidance")

        let bwsSaved = await store.upsertBWSBinding(alias: "cloud.hcloud.dev", projectID: "project-dev", secretID: "secret-dev", environment: "qa")
        try expect(!bwsSaved, "invalid BWS environment fails before IPC")
        try expect(store.errorMessage == "Choose a valid provider environment.", "invalid BWS environment shows guidance")

        let sessionCreated = await store.createProxySession(profileName: "openai", bindPort: 70_000)
        try expect(!sessionCreated, "invalid proxy session port fails before IPC")
        try expect(store.errorMessage == "Choose a bind port between 1 and 65535.", "invalid proxy session port shows guidance")
    }

    @MainActor
    private static func testOriginNormalization() async throws {
        let store = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [emptySnapshot()]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        await store.refresh()

        let proxySaved = await store.upsertProxy(
            name: "openai",
            origin: "api.openai.com",
            pathPrefixes: "/v1/",
            methods: "GET, POST",
            secretAlias: "ai.openai.dev",
            ttl: 900
        )
        try expect(proxySaved, "bare proxy host is normalized and saved")
        try expect(store.selectedProxyProfileSummary?.upstreamOrigin.absoluteString == "https://api.openai.com", "bare proxy host normalizes to https origin")

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
    private static func testDaemonInstallPlanState() async throws {
        let plan = smokeInstallPlan(supported: true, missingExecutables: [])
        try? FileManager.default.removeItem(atPath: plan.prefixPath)
        let installed = DaemonStatus(
            state: .unavailable,
            socketPath: plan.socketPath,
            launchAgentPath: plan.launchAgentPath,
            message: "Local daemon was installed. Open the installed app copy so the authenticated IPC manifest matches the running UI.",
            detail: nil,
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
        try expect(!store.canOpenInstalledApp, "installed app command is unavailable before the app copy exists")
        await store.installOrRepairDaemon()
        try FileManager.default.createDirectory(atPath: plan.appDestinationPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plan.prefixPath) }
        try expect(store.daemonStatus.message.contains("Open the installed app"), "install result explains installed app handoff")
        try expect(store.bestDaemonAction == .openInstalledApp, "installed-app handoff highlights open installed app as the next action")
        try expect(store.canOpenInstalledApp, "installed app command becomes available when the app copy exists")
        try expect(InstalledAppOpener.installedAppURL(store: store)?.path == plan.appDestinationPath, "installed app opener resolves the same app copy path used by diagnostics and commands")

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
    private static func testContextActions() async throws {
        let store = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [emptySnapshot()]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        await store.refresh()
        try expect(store.canRegisterCLI, "register CLI action is available when daemon is healthy")
        try expect(store.canExportAudit, "audit export is available after snapshot load")
        store.presentProxyProfileEditor()
        try expect(store.selectedSection == .proxy, "proxy editor action selects proxy section")
        try expect(store.showingProxyProfileEditor, "proxy editor action opens proxy sheet")
        store.showingProxyProfileEditor = false
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
        withResources.proxyProfiles = [
            ProxyProfileSummary(profile: ProxyProfile(
                name: "openai",
                upstreamOrigin: URL(string: "https://api.openai.com")!,
                allowedPathPrefixes: ["/v1/"],
                allowedMethods: ["GET", "POST"],
                secretAlias: "ai.openai.dev"
            )),
            ProxyProfileSummary(profile: ProxyProfile(
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
        withResources.bwsBindings = [
            BWSBindingSummary(
                binding: BWSSecretBinding(alias: "cloud.hcloud.dev", projectID: "project-dev", secretID: "secret-dev", environment: ProviderEnvironment.dev.rawValue),
                policy: BWSProviderLeasePolicy.policy(for: .dev)
            )
        ]
        withResources.adapters = [
            AdapterSummary(payload: BuiltInAdapterPacks.hcloud, adapterHash: AdapterCanonicalizer.hash(BuiltInAdapterPacks.hcloud), installedAt: Date())
        ]
        let store = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [withResources, withResources, withResources, withResources, withResources]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        await store.refresh()
        try expect(store.selectedProxyProfileSummary?.name == "openai", "proxy selection is initialized")
        try expect(store.selectedMCPProfileSummary?.name == "linear", "MCP selection is initialized")
        try expect(store.selectedBWSBindingSummary?.alias == "cloud.hcloud.dev", "BWS binding selection is initialized")
        try expect(store.selectedAdapterSummary?.cliName == "hcloud", "adapter selection is initialized")
        try expect(store.selectedCLIRegistration?.name == "hcloud", "CLI selection is initialized")

        let anchoredUnregisterStore = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [snapshot(cliNames: ["hcloud", "gh"])]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
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
        await store.replaceSecret(alias: "ai.openai.dev", value: "synthetic-secret", label: "OpenAI", environment: "proxy:openai")
        try expect(store.successMessage == "Secret replaced", "proxy secret replacement reports success")
        let sessionCreated = await store.createProxySession(profileName: "openai", bindPort: 48_177)
        try expect(sessionCreated, "valid proxy session succeeds")
        try expect(store.successMessage == "Proxy session created", "proxy session creation reports success")
        try expect(store.selectedProxySession?.token.isEmpty == false, "proxy session exposes one-time token")
        try expect(store.selectedProxySession?.endpoint.scheme == "http", "proxy session endpoint uses local http")
        try expect(store.selectedProxySession?.endpoint.host == "127.0.0.1", "proxy session exposes localhost endpoint")
        try expect(store.selectedProxySession?.endpoint.port == 48_177, "proxy session exposes requested bind port")
        try expect(store.selectedProxySession?.endpoint.path.hasPrefix("/openai/session/") == true, "proxy session endpoint scopes token path to profile")
        store.selectedProxyProfile = "anthropic"
        try expect(store.selectedProxySession == nil, "proxy one-time token is hidden when another profile is selected")
        store.selectedProxyProfile = "openai"
        try expect(store.selectedProxySession?.token.isEmpty == false, "proxy one-time token returns only for its owning profile")
        store.clearProxySession(profileName: "anthropic")
        try expect(store.selectedProxySession?.token.isEmpty == false, "clearing another profile does not hide the selected proxy token")
        store.clearProxySession(profileName: "openai")
        try expect(store.selectedProxySession == nil, "proxy one-time token can be explicitly hidden for its owning profile")
        let secondSessionCreated = await store.createProxySession(profileName: "openai", bindPort: 48_177)
        try expect(secondSessionCreated, "proxy session can be recreated after hiding one-time token")
        let proxyDeleted = await store.deleteProxyProfile(name: "openai")
        try expect(proxyDeleted, "proxy profile delete reports success flag")
        try expect(store.successMessage == "Proxy profile deleted", "proxy profile delete reports success")
        try expect(store.selectedProxySession == nil, "proxy one-time token is cleared after deleting its profile")
        let mcpDeleted = await store.deleteMCPProfile(name: "linear")
        try expect(mcpDeleted, "MCP profile delete reports success flag")
        try expect(store.successMessage == "MCP profile deleted", "MCP profile delete reports success")
        await store.upsertBWSBinding(alias: "cloud.hcloud.prod", projectID: "project-prod", secretID: "secret-prod", environment: ProviderEnvironment.prod.rawValue)
        try expect(store.successMessage == "BWS binding saved", "BWS binding save reports success")
        let bwsDeleted = await store.deleteBWSBinding(alias: "cloud.hcloud.dev")
        try expect(bwsDeleted, "BWS binding delete reports success flag")
        try expect(store.successMessage == "BWS binding deleted", "BWS binding delete reports success")
        let adapterRevoked = await store.revokeAdapter(adapterID: BuiltInAdapterPacks.hcloud.adapterID)
        try expect(adapterRevoked, "adapter revoke reports success flag")
        try expect(store.successMessage == "Adapter revoked", "adapter revoke reports success")
        let policySaved = await store.updateCommandPolicy(destructiveTerms: ["remove"], forbiddenTerms: ["shutdown"])
        try expect(policySaved, "command policy update reports success")
        try expect(store.successMessage == "Command policy saved", "command policy save reports success")
        await store.exportAudit()
        try expect(store.successMessage == "Audit loaded", "audit preview load reports success")
        try expect(store.exportedAudit == "[]", "audit preview stores redacted JSON")
        let exportPreview = await store.loadRedactedAuditForExport()
        try expect(exportPreview == "[]", "audit export loader returns redacted JSON")
        store.recordAuditExport(to: URL(fileURLWithPath: "/tmp/agentic-fortress-audit.json"))
        try expect(store.successMessage == "Audit exported to agentic-fortress-audit.json", "audit file export reports destination filename")
        store.recordExternalOpenFailure(label: "Provider Console", url: URL(string: "https://example.invalid/provider")!)
        try expect(store.errorMessage == "Could not open Provider Console. Copy this URL instead: https://example.invalid/provider", "external URL failures are recoverable with a copyable URL")
        try expect(LocalFileOpener.fileExists(atPath: "/bin/echo"), "local file opener accepts existing paths")
        store.recordLocalOpenFailure(label: "CLI executable", path: "/definitely/missing/agentic-fortress-cli")
        try expect(store.errorMessage == "Could not open CLI executable. Path is not available: /definitely/missing/agentic-fortress-cli", "local file open failures explain the missing path")
        await store.clearUnlockGrants()
        try expect(store.successMessage == "All grants locked", "grant locking reports success")
        store.selectedCLI = "hcloud"
        await store.unregisterSelectedCLI(deleteSecretMaterial: true)
        try expect(store.successMessage == "CLI unregistered", "CLI unregister reports success")
        try expect(store.selectedCLI == nil, "CLI unregister clears selection")
    }

    private static func testAuditRelatedItemRouting() throws {
        var withResources = snapshot(cliNames: ["hcloud"])
        withResources.proxyProfiles = [
            ProxyProfileSummary(profile: ProxyProfile(
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
        withResources.bwsBindings = [
            BWSBindingSummary(
                binding: BWSSecretBinding(alias: "cloud.hcloud.dev", projectID: "project-dev", secretID: "secret-dev", environment: ProviderEnvironment.dev.rawValue),
                policy: BWSProviderLeasePolicy.policy(for: .dev)
            )
        ]

        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .cliEnv, subjectID: "hcloud", secretID: "hcloud.token"), snapshot: withResources) == .cli("hcloud"), "audit CLI event routes to CLI registration")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .apiProxy, subjectID: "missing", secretID: "ai.openai.dev"), snapshot: withResources) == .proxy("openai"), "audit proxy event routes by secret alias")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .bwsProvider, subjectID: "missing", secretID: "cloud.hcloud.dev"), snapshot: withResources) == .bws("cloud.hcloud.dev"), "audit BWS event routes by binding alias")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .remoteMCP, subjectID: "linear", secretID: "mcp.linear"), snapshot: withResources) == .mcp("linear"), "audit MCP event routes to MCP profile")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .remoteSSHStdin, subjectID: "ssh", secretID: "ssh.key"), snapshot: withResources) == nil, "audit SSH event has no local route")
        try expect(AuditRelatedItemRouter.route(for: auditEvent(flow: .apiProxy, subjectID: "missing", secretID: "missing"), snapshot: withResources) == nil, "audit event without matching local item has no route")

        let cliEvent = auditEvent(flow: .cliEnv, subjectID: "hcloud", secretID: "hcloud.token")
        var proxyEvent = auditEvent(flow: .apiProxy, subjectID: "openai", secretID: "ai.openai.dev")
        proxyEvent.time = Date(timeIntervalSince1970: cliEvent.time.timeIntervalSince1970 + 1)
        let allEvents = [cliEvent, proxyEvent]
        let visibleEvents = AuditEventFilter.filtered(allEvents, query: "openai")
        try expect(visibleEvents.map(\.id) == [proxyEvent.id], "audit filter limits visible events")
        try expect(
            AuditEventFilter.selectedVisibleEvent(selectedID: cliEvent.id, visibleEvents: visibleEvents) == nil,
            "hidden audit selection is not actionable after filtering"
        )
        try expect(
            AuditEventFilter.selectedVisibleEvent(selectedID: proxyEvent.id, visibleEvents: visibleEvents) == proxyEvent,
            "visible audit selection remains actionable after filtering"
        )
    }

    @MainActor
    private static func testActivationRefreshLoadsMissingSnapshot() async throws {
        let store = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [snapshot(cliNames: ["hcloud"])]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        try expect(store.snapshot == nil, "activation test starts without snapshot")
        await store.refreshAfterActivation()
        try expect(store.snapshot?.cliRegistrations.first?.name == "hcloud", "activation refresh loads missing snapshot")
        await store.refreshAfterActivation()
        try expect(store.daemonStatus.state == .healthy, "activation refresh keeps daemon status current after snapshot load")
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
        try expect(store.usesToolbarSearch, "toolbar search is available on CLI section")
        store.selectedSection = .proxy
        try expect(!store.usesToolbarSearch, "toolbar search is hidden on sections that do not use the global query")
    }

    @MainActor
    private static func testMenuBarStatusReflectsDaemonHealth() async throws {
        var snapshotWithAudit = emptySnapshot()
        snapshotWithAudit.auditEvents = [
            auditEvent(flow: .cloudNativeIdentity, subjectID: "sensitive-subject", secretID: "secret-one"),
            auditEvent(flow: .apiProxy, subjectID: "proxy-subject", secretID: "secret-two"),
            auditEvent(flow: .remoteMCP, subjectID: "mcp-subject", secretID: "secret-three"),
            auditEvent(flow: .bwsProvider, subjectID: "bws-subject", secretID: "secret-four")
        ]
        let healthy = ManagementStore(
            client: SequenceAgenticFortressClient(snapshots: [snapshotWithAudit]),
            daemonController: StubDaemonStatusController(statusValue: healthyDaemonStatus())
        )
        await healthy.refresh()
        try expect(healthy.menuBarSummary == "Ok · 0 grants", "healthy menu summary includes health and grants")
        try expect(healthy.canRegisterCLI, "CLI registration is available when daemon is healthy")
        try expect(healthy.menuBarRecentActivityTitles.count == 3, "menu bar recent activity is capped at three items")
        try expect(healthy.menuBarRecentActivityTitles.allSatisfy { $0.count <= 30 }, "menu bar recent activity labels stay short")
        try expect(!healthy.menuBarRecentActivityTitles.contains { $0.contains("secret") || $0.contains("subject") }, "menu bar recent activity does not expose subject or secret identifiers")

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
            ),
            commandPolicy: CommandPolicySummary(config: .default)
        )
    }

    private static func auditEvent(flow: DeliveryFlow, subjectID: String, secretID: String) -> AuditEventSummary {
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

    private static func healthyDaemonStatus() -> DaemonStatus {
        DaemonStatus(
            state: .healthy,
            socketPath: "/tmp/agentic-fortress-ui-smoke.sock",
            launchAgentPath: "/tmp/com.agenticfortress.core.plist",
            message: "Core daemon is reachable.",
            detail: nil,
            recoveryCommand: nil,
            checkedAt: Date()
        )
    }

    private static func unavailableDaemonStatus() -> DaemonStatus {
        DaemonStatus(
            state: .unavailable,
            socketPath: "/tmp/missing-agentic-fortress-ui-smoke.sock",
            launchAgentPath: "/tmp/com.agenticfortress.core.plist",
            message: "Local daemon is not installed yet.",
            detail: "socket(\"connect: No such file or directory\")",
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
        guard let removed = lastSnapshot.cliRegistrations.first(where: { $0.name == request.name }) ?? lastSnapshot.cliRegistrations.first else {
            throw SmokeError.failed("missing CLI for unregister")
        }
        lastSnapshot.cliRegistrations.removeAll { $0.name == removed.name }
        snapshots.removeAll { snapshot in
            snapshot.cliRegistrations.contains(where: { $0.name == removed.name })
        }
        return removed
    }

    func refreshCLITrust(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary {
        lastSnapshot.cliRegistrations.first!
    }

    func replaceSecret(_ request: ManagementSecretReplacementRequest) async throws -> ManagedSecretSummary {
        ManagedSecretSummary(alias: request.alias, environment: request.environment, storeKind: "smoke", externalIDDigest: "sha256:smoke")
    }

    func deleteSecret(_ request: ManagementSecretDeletionRequest) async throws {}

    func upsertProxyProfile(_ profile: ProxyProfile) async throws -> ProxyProfileSummary {
        let summary = ProxyProfileSummary(profile: profile)
        lastSnapshot.proxyProfiles.removeAll { $0.name == summary.name }
        lastSnapshot.proxyProfiles.append(summary)
        lastSnapshot.proxyProfiles.sort { $0.name < $1.name }
        snapshots.removeAll()
        return summary
    }

    func deleteProxyProfile(_ request: ManagementNameRequest) async throws {}

    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary {
        let summary = MCPProfileSummary(profile: profile)
        lastSnapshot.mcpProfiles.removeAll { $0.name == summary.name }
        lastSnapshot.mcpProfiles.append(summary)
        lastSnapshot.mcpProfiles.sort { $0.name < $1.name }
        snapshots.removeAll()
        return summary
    }

    func deleteMCPProfile(_ request: ManagementNameRequest) async throws {}

    func upsertBWSBinding(_ binding: BWSSecretBinding) async throws -> BWSBindingSummary {
        BWSBindingSummary(binding: binding, policy: BWSProviderLeasePolicy.policy(for: ProviderEnvironment(rawValue: binding.environment) ?? .dev))
    }

    func deleteBWSBinding(_ request: ManagementNameRequest) async throws {}

    func installAdapter(_ payload: AdapterPackPayload) async throws -> AdapterSummary {
        AdapterSummary(payload: payload, adapterHash: AdapterCanonicalizer.hash(payload), installedAt: Date())
    }

    func revokeAdapter(_ request: ManagementNameRequest) async throws {}

    func updateCommandPolicy(_ request: ManagementCommandPolicyUpdateRequest) async throws -> CommandPolicySummary {
        CommandPolicySummary(config: request.config)
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
    func deleteProxyProfile(_ request: ManagementNameRequest) async throws { throw SmokeError.failed("unexpected proxy delete") }
    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary { throw SmokeError.failed("unexpected mcp") }
    func deleteMCPProfile(_ request: ManagementNameRequest) async throws { throw SmokeError.failed("unexpected mcp delete") }
    func upsertBWSBinding(_ binding: BWSSecretBinding) async throws -> BWSBindingSummary { throw SmokeError.failed("unexpected bws") }
    func deleteBWSBinding(_ request: ManagementNameRequest) async throws { throw SmokeError.failed("unexpected bws delete") }
    func installAdapter(_ payload: AdapterPackPayload) async throws -> AdapterSummary { throw SmokeError.failed("unexpected adapter install") }
    func revokeAdapter(_ request: ManagementNameRequest) async throws { throw SmokeError.failed("unexpected adapter revoke") }
    func updateCommandPolicy(_ request: ManagementCommandPolicyUpdateRequest) async throws -> CommandPolicySummary { CommandPolicySummary(config: request.config) }
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
            ),
            commandPolicy: CommandPolicySummary(config: .default)
        )
    }
}
