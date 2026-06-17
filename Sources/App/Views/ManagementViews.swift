import AgenticFortressCore
import AppKit
import SwiftUI

struct OverviewView: View {
    var store: ManagementStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header("Overview", subtitle: store.snapshot?.stateDirectory ?? "Loading local state")
                DaemonStatusPanel(store: store)
                if let snapshot = store.snapshot {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                        MetricTile(title: "CLIs", value: "\(snapshot.cliRegistrations.count)", systemImage: "terminal")
                        MetricTile(title: "Secrets", value: "\(snapshot.secrets.count)", systemImage: "key")
                        MetricTile(title: "Grants", value: "\(snapshot.unlockGrants.count)", systemImage: "timer")
                        MetricTile(title: "Audit", value: "\(snapshot.auditEvents.count)", systemImage: "list.bullet.clipboard")
                    }
                    StatusPanel(health: snapshot.securityHealth)
                    RecentActivityList(events: Array(snapshot.auditEvents.prefix(6)))
                } else {
                    SnapshotUnavailablePanel(store: store)
                }
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct CLISecretsView: View {
    @Bindable var store: ManagementStore
    @State private var pendingUnregister: CLIRegistrationSummary?
    @State private var deleteSecrets = false

    var body: some View {
        Group {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.snapshot?.cliRegistrations.isEmpty == true {
                NoCLIRegistrationsView(store: store)
            } else if store.filteredCLIRegistrations.isEmpty {
                NoMatchingCLIView(store: store)
            } else {
                HSplitView {
                    CLIRegistrationList(store: store)
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    CLIRegistrationDetail(
                        store: store,
                        pendingUnregister: $pendingUnregister
                    )
                    .frame(minWidth: 420)
                }
            }
        }
        .confirmationDialog("Unregister CLI?", isPresented: Binding(
            get: { pendingUnregister != nil },
            set: { if !$0 { pendingUnregister = nil } }
        )) {
            Toggle("Delete secret material too", isOn: $deleteSecrets)
            Button("Unregister", role: .destructive) {
                Task { await store.unregisterSelectedCLI(deleteSecretMaterial: deleteSecrets) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Secret values will never be shown. Delete secret material only if you are sure no binding should keep it.")
        }
    }
}

private struct CLIRegistrationList: View {
    @Bindable var store: ManagementStore

    var body: some View {
        List(selection: $store.selectedCLI) {
            ForEach(store.filteredCLIRegistrations) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.headline)
                    Text(item.environmentBindings.map(\.environmentName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(Optional(item.name))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.name), \(item.environmentBindings.count) bindings")
            }
        }
    }
}

private struct CLIRegistrationDetail: View {
    @Bindable var store: ManagementStore
    @Binding var pendingUnregister: CLIRegistrationSummary?

    var body: some View {
        ScrollView {
            if let cli = store.selectedCLIRegistration {
                VStack(alignment: .leading, spacing: 18) {
                    header(cli.name, subtitle: cli.targetPath)
                    HStack {
                        StatusBadge(text: cli.trustStatus, systemImage: "checkmark.shield")
                        StatusBadge(text: cli.shimStatus, systemImage: "link")
                    }
                    Form {
                        Section("Environment bindings") {
                            ForEach(cli.environmentBindings, id: \.environmentName) { binding in
                                SecretBindingRow(store: store, binding: binding, cliName: cli.name)
                            }
                        }
                        Section("Target identity") {
                            LabeledContent("Resolved path", value: cli.targetResolvedPath ?? "Unknown")
                            LabeledContent("Identity", value: cli.targetIdentity ?? "Unknown")
                            LabeledContent("CDHash", value: cli.targetCDHash ?? "Unknown")
                            LabeledContent("Signing ID", value: cli.targetSigningIdentifier ?? "Unknown")
                            LabeledContent("Team ID", value: cli.targetTeamIdentifier ?? "Unknown")
                        }
                    }
                    HStack {
                        Button("Refresh Trust") {
                            Task { await store.refreshTrust(for: cli.name) }
                        }
                        .help("Refresh trust metadata for this executable")
                        Button("Unregister", role: .destructive) {
                            pendingUnregister = cli
                        }
                        .help("Remove this CLI registration")
                    }
                }
                .padding(24)
                .frame(maxWidth: 920, alignment: .leading)
            } else {
                NoMatchingCLIView(store: store)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct NoCLIRegistrationsView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        ContentUnavailableView {
            Label("No CLI Registered", systemImage: "terminal")
        } description: {
            Text("Register a CLI to bind secret delivery to a trusted executable.")
        } actions: {
            Button {
                store.presentRegisterCLI()
            } label: {
                Label("Register CLI", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canRegisterCLI)
            .help("Start the CLI registration wizard")
        }
    }
}

private struct NoMatchingCLIView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        ContentUnavailableView {
            Label("No Matching CLIs", systemImage: "magnifyingglass")
        } description: {
            Text("No registered CLI, alias, or target matches this search.")
        } actions: {
            Button {
                store.searchText = ""
            } label: {
                Label("Clear Search", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .help("Clear the current search query")
        }
    }
}

struct SecretBindingRow: View {
    @Bindable var store: ManagementStore
    var binding: CLIEnvironmentBinding
    var cliName: String
    @State private var showingReplace = false
    @State private var showingDelete = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(binding.environmentName)
                Text(binding.secretAlias)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Replace") { showingReplace = true }
            Button("Delete", role: .destructive) { showingDelete = true }
        }
        .sheet(isPresented: $showingReplace) {
            ReplaceSecretView(store: store, alias: binding.secretAlias, label: "\(cliName) \(binding.environmentName)", environment: "cli:\(cliName)")
        }
        .confirmationDialog("Delete secret material?", isPresented: $showingDelete) {
            Button("Delete Secret Material", role: .destructive) {
                Task { await store.deleteSecret(alias: binding.secretAlias) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes encrypted local material for \(binding.secretAlias). The value cannot be revealed first.")
        }
    }
}

struct ProxyProfilesView: View {
    @Bindable var store: ManagementStore
    @State private var sessionProfile = ""
    @State private var bindPort = 48177

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Proxy", subtitle: "Bounded localhost sessions")

            List {
                ForEach(store.snapshot?.proxyProfiles ?? []) { profile in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(profile.name).font(.headline)
                            Text(profile.upstreamOrigin.absoluteString).foregroundStyle(.secondary)
                            Text("\(profile.allowedMethods.joined(separator: ", ")) · \(profile.allowedPathPrefixes.joined(separator: ", ")) · \(Int(profile.tokenTTLSeconds))s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            sessionProfile = profile.name
                            Task { await store.createProxySession(profileName: profile.name, bindPort: bindPort) }
                        } label: {
                            Label("Create Session", systemImage: "bolt.horizontal")
                        }
                        .help("Create a one-time localhost proxy session for \(profile.name)")
                    }
                    .contextMenu {
                        Button("Create Session") {
                            sessionProfile = profile.name
                            Task { await store.createProxySession(profileName: profile.name, bindPort: bindPort) }
                        }
                    }
                }
            }

            Form {
                Section("Session") {
                    Stepper(value: $bindPort, in: 1024...65535) {
                        Text("Bind port: \(bindPort.formatted(.number.grouping(.never)))")
                    }
                    .help("Local port for the next proxy session")
                }
                if let token = store.oneTimeProxyToken {
                    CopyableSecretOnceView(title: "One-time proxy token", value: token)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 170)
        }
        .padding(24)
        .overlay {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.snapshot?.proxyProfiles.isEmpty == true {
                ContentUnavailableView {
                    Label("No Proxy Profiles", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Create a bounded localhost proxy profile before starting proxy sessions.")
                } actions: {
                    Button {
                        store.presentProxyProfileEditor()
                    } label: {
                        Label("Add Proxy Profile", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canManageCoreState)
                }
            }
        }
    }
}

struct MCPProfilesView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        List {
            ForEach(store.snapshot?.mcpProfiles ?? []) { profile in
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.headline)
                    Text(profile.origin.absoluteString).foregroundStyle(.secondary)
                    Text("\(profile.authorizationHeaderName) · \(profile.allowedPathPrefixes.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.snapshot?.mcpProfiles.isEmpty == true {
                ContentUnavailableView {
                    Label("No MCP Profiles", systemImage: "server.rack")
                } description: {
                    Text("Pinned MCP upstreams keep authorization injection bounded.")
                } actions: {
                    Button {
                        store.presentMCPProfileEditor()
                    } label: {
                        Label("Add MCP Profile", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canManageCoreState)
                }
            }
        }
    }
}

struct BWSView: View {
    var store: ManagementStore

    var body: some View {
        List {
            ForEach(store.snapshot?.bwsBindings ?? []) { binding in
                VStack(alignment: .leading) {
                    Text(binding.alias).font(.headline)
                    Text("\(binding.environment) · lease \(Int(binding.maxLeaseSeconds))s · \(binding.secretIDDigest)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.snapshot?.bwsBindings.isEmpty == true {
                ContentUnavailableView {
                    Label("No BWS Bindings", systemImage: "key.horizontal")
                } description: {
                    Text("BWS runtime remains one approved secret per invocation. Binding management is configured through core/provider setup.")
                } actions: {
                    Button {
                        store.presentDiagnostics()
                    } label: {
                        Label("Review Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Review local core and provider setup")
                }
            }
        }
    }
}

struct AdaptersView: View {
    var store: ManagementStore

    var body: some View {
        Table(store.snapshot?.adapters ?? []) {
            TableColumn("CLI", value: \.cliName)
            TableColumn("Publisher", value: \.publisher)
            TableColumn("Version") { Text("\($0.adapterVersion)") }
            TableColumn("Rules") { Text("\($0.ruleCount)") }
            TableColumn("Hash") { Text($0.adapterHash).lineLimit(1) }
        }
        .padding()
        .overlay {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.snapshot?.adapters.isEmpty == true {
                ContentUnavailableView {
                    Label("No Adapters", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Install a signed adapter pack JSON payload to classify a supported CLI.")
                } actions: {
                    Button {
                        AdapterPackInstaller.presentOpenPanel(store: store)
                    } label: {
                        Label("Install Adapter Pack", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canManageCoreState)
                }
            }
        }
    }
}

struct AuditView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                header("Audit", subtitle: "Redacted events only")
                Spacer()
                Button("Export Redacted JSON") {
                    Task { await store.exportAudit() }
                }
            }
            Table(store.snapshot?.auditEvents ?? []) {
                TableColumn("Time") { Text($0.time, style: .time) }
                TableColumn("Decision", value: \.decision)
                TableColumn("Flow") { Text($0.flow.rawValue) }
                TableColumn("Action", value: \.actionClass)
                TableColumn("Outcome", value: \.outcome)
            }
            .overlay {
                if store.snapshot == nil {
                    LocalStateUnavailableView(store: store)
                } else if store.snapshot?.auditEvents.isEmpty == true {
                    ContentUnavailableView {
                        Label("No Audit Events", systemImage: "list.bullet.clipboard")
                    } description: {
                        Text("Audit events appear after approved or denied secret delivery decisions.")
                    } actions: {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Refresh State", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            if let exported = store.exportedAudit {
                TextEditor(text: .constant(exported))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 140)
            }
        }
        .padding(24)
    }
}

struct DiagnosticsView: View {
    @Bindable var store: ManagementStore
    @State private var confirmingInstall = false

    var body: some View {
        Form {
            Section("Daemon") {
                LabeledContent("Status", value: store.daemonStatus.state.rawValue.capitalized)
                LabeledContent("Socket", value: store.daemonStatus.socketPath)
                LabeledContent("LaunchAgent", value: store.daemonStatus.launchAgentPath ?? "Not installed")
                Text(store.daemonStatus.message)
                    .foregroundStyle(store.daemonStatus.state == .healthy ? .secondary : .primary)
                if let detail = store.daemonStatus.detail {
                    DisclosureGroup("Technical details") {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    DaemonActionButtons(store: store, confirmingInstall: $confirmingInstall, includeAdvancedActions: true)
                }
                if let plan = store.daemonInstallPlan {
                    DaemonInstallPlanView(plan: plan)
                }
            }
            Section("State") {
                LabeledContent("State directory", value: store.snapshot?.stateDirectory ?? "Unknown")
                LabeledContent("Config path", value: store.snapshot?.configPath ?? "Unknown")
            }
            Section("Compatibility") {
                LabeledContent("Runtime major", value: "\(store.snapshot?.securityHealth.runtimeMajor ?? 0)")
                LabeledContent("Required SDK major", value: "\(store.snapshot?.securityHealth.requiredSDKMajor ?? 0)")
                LabeledContent("IPC protocol", value: "\(store.snapshot?.securityHealth.protocolVersion ?? 0)")
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .confirmationDialog(
            store.daemonInstallPlan?.primaryActionTitle ?? "Install Local Daemon",
            isPresented: $confirmingInstall,
            titleVisibility: .visible
        ) {
            Button(store.daemonInstallPlan?.primaryActionTitle ?? "Install Local Daemon") {
                Task { await store.installOrRepairDaemon() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agentic Fortress will update the local app copy, helper links, install manifest, and per-user LaunchAgent. Secret material is not read or moved.")
        }
    }
}

struct SnapshotUnavailablePanel: View {
    @Bindable var store: ManagementStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
            if store.daemonStatus.state == .healthy {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh State", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isLoading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        store.daemonStatus.state == .healthy ? "Local State Not Loaded" : "Local State Paused"
    }

    private var message: String {
        store.daemonStatus.state == .healthy
            ? "Refresh to load local Agentic Fortress state."
            : "Local state will load after the daemon is reachable."
    }

    private var symbol: String {
        store.daemonStatus.state == .healthy ? "shield" : "pause.circle"
    }
}

struct LocalStateUnavailableView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        ContentUnavailableView {
            Label("Local State Unavailable", systemImage: "pause.circle")
        } description: {
            Text("This page will load after the local daemon is reachable.")
        } actions: {
            Button {
                store.presentDiagnostics()
            } label: {
                Label("Open Diagnostics", systemImage: "stethoscope")
            }
            .buttonStyle(.borderedProminent)
            .help("Open daemon diagnostics and repair actions")
        }
    }
}

struct DaemonStatusPanel: View {
    @Bindable var store: ManagementStore
    @State private var confirmingInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                if store.daemonStatus.state == .repairing || store.daemonStatus.state == .installing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(store.daemonStatus.message)
                .foregroundStyle(.secondary)
            DaemonActionButtons(store: store, confirmingInstall: $confirmingInstall, includeAdvancedActions: false)
            if let plan = store.daemonInstallPlan, !plan.canInstall {
                Text(plan.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog(
            store.daemonInstallPlan?.primaryActionTitle ?? "Install Local Daemon",
            isPresented: $confirmingInstall,
            titleVisibility: .visible
        ) {
            Button(store.daemonInstallPlan?.primaryActionTitle ?? "Install Local Daemon") {
                Task { await store.installOrRepairDaemon() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the local app copy, helper links, install manifest, and per-user LaunchAgent. Secret material is not read or moved.")
        }
    }

    private var title: String {
        switch store.daemonStatus.state {
        case .healthy: "Daemon Healthy"
        case .unavailable: "Daemon Unavailable"
        case .repairing: "Restarting Daemon"
        case .installing: "Installing Daemon"
        case .unknown: "Daemon Status Unknown"
        }
    }

    private var symbol: String {
        switch store.daemonStatus.state {
        case .healthy: "checkmark.circle"
        case .unavailable: "exclamationmark.triangle"
        case .repairing: "arrow.clockwise"
        case .installing: "tray.and.arrow.down"
        case .unknown: "questionmark.circle"
        }
    }
}

struct DaemonActionButtons: View {
    @Bindable var store: ManagementStore
    @Binding var confirmingInstall: Bool
    var includeAdvancedActions: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(visibleActions, id: \.self) { action in
                actionButton(action, prominent: action == store.bestDaemonAction)
            }
        }
    }

    private var visibleActions: [DaemonNextAction] {
        var actions: [DaemonNextAction] = []
        if let best = store.bestDaemonAction {
            actions.append(best)
        }

        if includeAdvancedActions {
            appendIfAvailable(.check, to: &actions)
            appendIfAvailable(.installOrRepair, to: &actions)
            appendIfAvailable(.restart, to: &actions)
            appendIfAvailable(.openInstalledApp, to: &actions)
        } else if store.daemonStatus.state != .healthy {
            appendIfAvailable(.check, to: &actions)
        } else {
            appendIfAvailable(.check, to: &actions)
        }
        return actions
    }

    private func appendIfAvailable(_ action: DaemonNextAction, to actions: inout [DaemonNextAction]) {
        guard !actions.contains(action), isAvailable(action) else { return }
        actions.append(action)
    }

    private func isAvailable(_ action: DaemonNextAction) -> Bool {
        switch action {
        case .check:
            return true
        case .installOrRepair:
            return store.daemonStatus.state != .healthy && store.daemonInstallPlan != nil
        case .restart:
            return store.daemonStatus.state != .healthy && store.daemonStatus.canRepair
        case .openInstalledApp:
            guard let plan = store.daemonInstallPlan, !plan.currentAppIsInstalledCopy else { return false }
            return FileManager.default.fileExists(atPath: plan.appDestinationPath)
        }
    }

    private func isDisabled(_ action: DaemonNextAction) -> Bool {
        if store.daemonStatus.state == .installing || store.daemonStatus.state == .repairing {
            return true
        }
        switch action {
        case .check:
            return store.isLoading
        case .installOrRepair:
            return !(store.daemonInstallPlan?.canInstall ?? false)
        case .restart:
            return !store.daemonStatus.canRepair
        case .openInstalledApp:
            guard let plan = store.daemonInstallPlan else { return true }
            return !FileManager.default.fileExists(atPath: plan.appDestinationPath)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: DaemonNextAction, prominent: Bool) -> some View {
        let button = Button {
            perform(action)
        } label: {
            Label(action.title(plan: store.daemonInstallPlan), systemImage: action.systemImage)
        }
        .accessibilityLabel(action.title(plan: store.daemonInstallPlan))
        .disabled(isDisabled(action))

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func perform(_ action: DaemonNextAction) {
        switch action {
        case .check:
            Task { await store.checkDaemon() }
        case .installOrRepair:
            confirmingInstall = true
        case .restart:
            Task { await store.repairDaemon() }
        case .openInstalledApp:
            guard let plan = store.daemonInstallPlan else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: plan.appDestinationPath, isDirectory: true))
        }
    }
}

struct DaemonInstallPlanView: View {
    var plan: DaemonInstallPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.title, systemImage: plan.canInstall ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.headline)
            Text(plan.summary)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                pathRow("Install prefix", plan.prefixPath)
                pathRow("App copy", plan.appDestinationPath)
                pathRow("Helpers", plan.binDirectoryPath)
                pathRow("LaunchAgent", plan.launchAgentPath)
                pathRow("Manifest", plan.manifestPath)
                pathRow("Socket", plan.socketPath)
            }
            if !plan.missingExecutables.isEmpty {
                Text("Missing helpers: \(plan.missingExecutables.joined(separator: ", "))")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Open Install Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: plan.prefixPath, isDirectory: true))
                }
                .disabled(!FileManager.default.fileExists(atPath: plan.prefixPath))
                Button("Open Installed App") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: plan.appDestinationPath, isDirectory: true))
                }
                .disabled(!FileManager.default.fileExists(atPath: plan.appDestinationPath))
            }
        }
    }

    private func pathRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(value).font(.title.bold())
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusPanel: View {
    var health: SecurityHealthSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(health.status.rawValue.capitalized, systemImage: health.status == .ok ? "checkmark.shield" : "exclamationmark.shield")
                .font(.headline)
            if health.attentionItems.isEmpty {
                Text("No attention items.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(health.attentionItems, id: \.self) { Text($0) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RecentActivityList: View {
    var events: [AuditEventSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity").font(.headline)
            if events.isEmpty {
                Text("No audit events yet.").foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    HStack {
                        Text(event.decision).font(.headline)
                        Text(event.actionClass).foregroundStyle(.secondary)
                        Spacer()
                        Text(event.time, style: .relative).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }
}

struct StatusBadge: View {
    var text: String
    var systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

func header(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.largeTitle.bold())
        Text(subtitle).foregroundStyle(.secondary)
    }
}
