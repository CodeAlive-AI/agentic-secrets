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
                    HStack(spacing: 12) {
                        MetricTile(title: "CLIs", value: "\(snapshot.cliRegistrations.count)", systemImage: "terminal")
                        MetricTile(title: "Secrets", value: "\(snapshot.secrets.count)", systemImage: "key")
                        MetricTile(title: "Grants", value: "\(snapshot.unlockGrants.count)", systemImage: "timer")
                        MetricTile(title: "Audit", value: "\(snapshot.auditEvents.count)", systemImage: "list.bullet.clipboard")
                    }
                    StatusPanel(health: snapshot.securityHealth)
                    RecentActivityList(events: Array(snapshot.auditEvents.prefix(6)))
                } else {
                    ContentUnavailableView("No Snapshot", systemImage: "shield", description: Text("Refresh to load local Agentic Fortress state."))
                }
            }
            .padding(24)
        }
    }
}

struct CLISecretsView: View {
    @Bindable var store: ManagementStore
    @State private var pendingUnregister: CLIRegistrationSummary?
    @State private var deleteSecrets = false

    var body: some View {
        HSplitView {
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
                }
            }
            .frame(minWidth: 240, idealWidth: 280)

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
                            Button("Unregister", role: .destructive) {
                                pendingUnregister = cli
                            }
                        }
                    }
                    .padding(24)
                } else {
                    ContentUnavailableView("No CLI Registered", systemImage: "terminal", description: Text("Register a CLI to bind secret delivery to a trusted executable."))
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
    @State private var showingEditor = false
    @State private var sessionProfile = ""
    @State private var bindPort = 48177

    var body: some View {
        List {
            Section {
                ForEach(store.snapshot?.proxyProfiles ?? []) { profile in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.name).font(.headline)
                        Text(profile.upstreamOrigin.absoluteString).foregroundStyle(.secondary)
                        Text("\(profile.allowedMethods.joined(separator: ", ")) · \(profile.allowedPathPrefixes.joined(separator: ", ")) · \(Int(profile.tokenTTLSeconds))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Create Session") {
                            sessionProfile = profile.name
                            Task { await store.createProxySession(profileName: profile.name, bindPort: bindPort) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Proxy Profiles")
                    Spacer()
                    Button("Add") { showingEditor = true }
                }
            }
            Section("Session") {
                Stepper("Bind port: \(bindPort)", value: $bindPort, in: 1024...65535)
                if let token = store.oneTimeProxyToken {
                    CopyableSecretOnceView(title: "One-time proxy token", value: token)
                }
            }
        }
        .listStyle(.inset)
        .sheet(isPresented: $showingEditor) {
            ProxyProfileEditor(store: store)
        }
    }
}

struct MCPProfilesView: View {
    @Bindable var store: ManagementStore
    @State private var showingEditor = false

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
            if store.snapshot?.mcpProfiles.isEmpty ?? true {
                ContentUnavailableView("No MCP Profiles", systemImage: "server.rack", description: Text("Pinned MCP upstreams keep authorization injection bounded."))
            }
        }
        .toolbar {
            Button("Add MCP Profile") { showingEditor = true }
        }
        .sheet(isPresented: $showingEditor) {
            MCPProfileEditor(store: store)
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
            if store.snapshot?.bwsBindings.isEmpty ?? true {
                ContentUnavailableView("No BWS Bindings", systemImage: "key.horizontal", description: Text("BWS runtime remains one approved secret per invocation."))
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
                HStack {
                    Button("Check") {
                        Task { await store.checkDaemon() }
                    }
                    if let plan = store.daemonInstallPlan {
                        Button(plan.primaryActionTitle) {
                            confirmingInstall = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!plan.canInstall || store.daemonStatus.state == .installing || store.daemonStatus.state == .repairing)
                    }
                    Button("Restart Daemon") {
                        Task { await store.repairDaemon() }
                    }
                    .disabled(!store.daemonStatus.canRepair || store.daemonStatus.state == .repairing || store.daemonStatus.state == .installing)
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
            HStack {
                Button("Check") {
                    Task { await store.checkDaemon() }
                }
                if let plan = store.daemonInstallPlan, store.daemonStatus.state != .healthy {
                    Button(plan.primaryActionTitle) {
                        confirmingInstall = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.canInstall || store.daemonStatus.state == .installing || store.daemonStatus.state == .repairing)
                }
                if store.daemonStatus.state != .healthy {
                    Button("Restart Daemon") {
                        Task { await store.repairDaemon() }
                    }
                    .disabled(!store.daemonStatus.canRepair || store.daemonStatus.state == .repairing || store.daemonStatus.state == .installing)
                }
                if let plan = store.daemonInstallPlan, !plan.currentAppIsInstalledCopy {
                    Button("Open Installed App") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: plan.appDestinationPath, isDirectory: true))
                    }
                    .disabled(!FileManager.default.fileExists(atPath: plan.appDestinationPath))
                }
            }
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
