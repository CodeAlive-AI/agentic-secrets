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
            set: {
                if !$0 {
                    pendingUnregister = nil
                    deleteSecrets = false
                }
            }
        )) {
            Toggle("Delete secret material too", isOn: $deleteSecrets)
            Button("Unregister \(pendingUnregister?.name ?? "CLI")", role: .destructive) {
                guard let cli = pendingUnregister else { return }
                let shouldDeleteSecrets = deleteSecrets
                pendingUnregister = nil
                deleteSecrets = false
                Task { await store.unregisterCLI(name: cli.name, deleteSecretMaterial: shouldDeleteSecrets) }
            }
            .disabled(!store.canManageCoreState)
            Button("Cancel", role: .cancel) {
                pendingUnregister = nil
                deleteSecrets = false
            }
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
    @State private var pendingShimRemoval: CLIRegistrationSummary?

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
                            HStack {
                                Button {
                                    Task { await store.refreshTrust(for: cli.name) }
                                } label: {
                                    Label("Refresh Trust", systemImage: "arrow.clockwise")
                                }
                                .disabled(!store.canManageCoreState)
                                .help("Refresh trust metadata for this executable")
                                CopyButton(title: "Copy Identity", value: cli.targetIdentity ?? "", help: "Copy target identity")
                                .disabled(cli.targetIdentity == nil)
                                CopyButton(title: "Copy CDHash", value: cli.targetCDHash ?? "", help: "Copy target CDHash")
                                .disabled(cli.targetCDHash == nil)
                            }
                        }
                        Section("Shim") {
                            LabeledContent("Status", value: cli.shimStatus)
                            HStack {
                                Button {
                                    Task { await store.installShim(for: cli.name) }
                                } label: {
                                    Label(cli.shimStatus == "installed" ? "Repair Shim" : "Install Shim", systemImage: "link")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!store.canManageCoreState)
                                .help("Install or repair the local command shim for this CLI")
                                Button("Remove Shim", role: .destructive) {
                                    pendingShimRemoval = cli
                                }
                                .disabled(!store.canManageCoreState)
                                .help("Remove the local command shim for this CLI")
                            }
                            Text("A shim routes normal \(cli.name) invocations through Agentic Fortress when the local shims folder is before the native CLI on PATH.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Section("Grants") {
                            LabeledContent("Active grants", value: "\(store.snapshot?.unlockGrants.count ?? 0)")
                            Button {
                                Task { await store.clearUnlockGrants() }
                            } label: {
                                Label("Lock All Grants on This Mac", systemImage: "lock")
                            }
                            .disabled(!store.canClearUnlockGrants)
                            .help("Clear every active authorization grant on this Mac. Scoped CLI grant clearing is not available in the current core contract.")
                        }
                        Section("Danger Zone") {
                            Button("Unregister CLI", role: .destructive) {
                                pendingUnregister = cli
                            }
                            .disabled(!store.canManageCoreState)
                            .help("Remove this CLI registration")
                        }
                    }
                    HStack {
                        Button {
                            LocalFileOpener.reveal(
                                path: cli.targetResolvedPath ?? cli.targetPath,
                                label: "\(cli.name) executable",
                                store: store
                            )
                        } label: {
                            Label("Reveal Executable in Finder", systemImage: "finder")
                        }
                        .disabled((cli.targetResolvedPath ?? cli.targetPath).isEmpty)
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
        .confirmationDialog("Remove command shim?", isPresented: Binding(
            get: { pendingShimRemoval != nil },
            set: { if !$0 { pendingShimRemoval = nil } }
        )) {
            Button("Remove Shim", role: .destructive) {
                guard let cli = pendingShimRemoval else { return }
                pendingShimRemoval = nil
                Task { await store.uninstallShim(for: cli.name) }
            }
            .disabled(!store.canManageCoreState)
            Button("Cancel", role: .cancel) {
                pendingShimRemoval = nil
            }
        } message: {
            Text("Normal \(pendingShimRemoval?.name ?? "CLI") invocations will stop routing through Agentic Fortress until the shim is installed again.")
        }
    }
}

private struct NoCLIRegistrationsView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        PageCenteredState {
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
}

private struct NoMatchingCLIView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        PageCenteredState {
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
                .disabled(!store.canManageCoreState)
                .help(store.canManageCoreState ? "Replace write-only secret material" : "Repair the daemon before replacing secret material")
            Button("Delete", role: .destructive) { showingDelete = true }
                .disabled(!store.canManageCoreState)
                .help(store.canManageCoreState ? "Delete write-only secret material" : "Repair the daemon before deleting secret material")
        }
        .sheet(isPresented: $showingReplace) {
            ReplaceSecretView(store: store, alias: binding.secretAlias, label: "\(cliName) \(binding.environmentName)", environment: "cli:\(cliName)")
        }
        .confirmationDialog("Delete secret material?", isPresented: $showingDelete) {
            Button("Delete Secret Material", role: .destructive) {
                Task { await store.deleteSecret(alias: binding.secretAlias) }
            }
            .disabled(!store.canManageCoreState)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes encrypted local material for \(binding.secretAlias). The value cannot be revealed first.")
        }
    }
}

struct ProxyProfilesView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        ManagementPageFrame(
            title: "Proxy",
            subtitle: "Bounded localhost sessions that keep upstream API keys out of client apps."
        ) {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.proxyProfiles.isEmpty {
                PageCenteredState {
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
            } else {
                HSplitView {
                    List(selection: $store.selectedProxyProfile) {
                        ForEach(store.proxyProfiles) { profile in
                            ProxyProfileRow(profile: profile)
                                .tag(Optional(profile.name))
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

                    ProxyProfileDetail(store: store)
                        .frame(minWidth: 480)
                }
                .frame(minHeight: 440)
            }
        }
    }
}

private struct ProxyProfileRow: View {
    var profile: ProxyProfileSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.name).font(.headline)
                Spacer()
                Text("\(Int(profile.tokenTTLSeconds))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(profile.upstreamOrigin.host() ?? profile.upstreamOrigin.absoluteString)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(profile.allowedMethods.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Proxy profile \(profile.name)")
    }
}

private struct ProxyProfileDetail: View {
    @Bindable var store: ManagementStore
    @State private var bindPort = 48177
    @State private var showingEdit = false
    @State private var showingReplaceSecret = false
    @State private var confirmingDeleteSecret = false
    @State private var confirmingDeleteProfile = false
    @State private var deleteCredentialWithProfile = false

    var body: some View {
        ScrollView {
            if let profile = store.selectedProxyProfileSummary {
                VStack(alignment: .leading, spacing: 18) {
                    header(profile.name, subtitle: profile.upstreamOrigin.absoluteString)
                    Form {
                        Section("Configuration") {
                            LabeledContent("Allowed methods", value: profile.allowedMethods.joined(separator: ", "))
                            LabeledContent("Path prefixes", value: profile.allowedPathPrefixes.joined(separator: ", "))
                            LabeledContent("Session TTL", value: "\(Int(profile.tokenTTLSeconds))s")
                            Button {
                                showingEdit = true
                            } label: {
                                Label("Edit Profile", systemImage: "slider.horizontal.3")
                            }
                            .disabled(!store.canManageCoreState)
                            .help("Update origin, allowed paths, methods, secret alias, and session TTL")
                        }
                        Section("Credential") {
                            LabeledContent("Status", value: "Alias configured")
                            LabeledContent("Secret alias", value: profile.secretAlias)
                            Text("Use Replace API Key to write or rotate material. Saved values are never returned to the UI.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button {
                                    showingReplaceSecret = true
                                } label: {
                                    Label("Replace API Key", systemImage: "key.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!store.canManageCoreState)
                                .help("Write a replacement upstream API key. The saved value is never shown.")
                                Button("Delete API Key", role: .destructive) {
                                    confirmingDeleteSecret = true
                                }
                                .disabled(!store.canManageCoreState)
                                .help("Delete stored credential material for this proxy alias")
                                if let dashboard = ProviderDashboardResolver.link(for: profile) {
                                    Button {
                                        ExternalURLOpener.open(dashboard.url, label: dashboard.title, store: store)
                                    } label: {
                                        Label(dashboard.title, systemImage: "arrow.up.right.square")
                                    }
                                    .help("Open provider key management in your browser")
                                }
                            }
                        }
                        Section("Session") {
                            Stepper(value: $bindPort, in: 1024...65535) {
                                Text("Bind port: \(bindPort.formatted(.number.grouping(.never)))")
                            }
                            .help("Local port for the next proxy session")
                            Button {
                                Task { await store.createProxySession(profileName: profile.name, bindPort: bindPort) }
                            } label: {
                                Label("Create Session", systemImage: "bolt.horizontal")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canManageCoreState)
                            .help("Create a one-time localhost proxy session for this profile")
                            if let endpoint = store.selectedProxySession?.endpoint {
                                CopyableValueView(title: "Proxy URL", value: endpoint.absoluteString)
                            }
                            if let token = store.selectedProxySession?.token {
                                CopyableSecretOnceView(title: "One-time proxy token", value: token)
                                Button {
                                    store.clearProxySession(profileName: profile.name)
                                } label: {
                                    Label("Hide Token", systemImage: "eye.slash")
                                }
                                .help("Hide this one-time token from the UI. It will not revoke an already copied token.")
                            }
                        }
                        Section("Danger Zone") {
                            Toggle("Delete API key material too", isOn: $deleteCredentialWithProfile)
                            Button("Delete Profile", role: .destructive) {
                                confirmingDeleteProfile = true
                            }
                            .disabled(!store.canManageCoreState)
                            .help("Remove this proxy profile. Credential material is kept unless the checkbox is selected.")
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .sheet(isPresented: $showingEdit) {
                    ProxyProfileEditor(store: store, profile: profile)
                }
                .sheet(isPresented: $showingReplaceSecret) {
                    ReplaceSecretView(store: store, alias: profile.secretAlias, label: "\(profile.name) proxy API key", environment: "proxy:\(profile.name)")
                }
                .confirmationDialog("Delete API key?", isPresented: $confirmingDeleteSecret) {
                    Button("Delete API Key", role: .destructive) {
                        Task { await store.deleteSecret(alias: profile.secretAlias) }
                    }
                    .disabled(!store.canManageCoreState)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes local encrypted material for \(profile.secretAlias). The saved value cannot be displayed first.")
                }
                .confirmationDialog("Delete proxy profile?", isPresented: $confirmingDeleteProfile) {
                    Button("Delete Profile", role: .destructive) {
                        let shouldDeleteCredential = deleteCredentialWithProfile
                        deleteCredentialWithProfile = false
                        Task {
                            await store.deleteProxyProfile(
                                name: profile.name,
                                deleteSecretAlias: shouldDeleteCredential ? profile.secretAlias : nil
                            )
                        }
                    }
                    .disabled(!store.canManageCoreState)
                    Button("Cancel", role: .cancel) {
                        deleteCredentialWithProfile = false
                    }
                } message: {
                    Text("The profile is removed from local configuration. Secret material is deleted only if selected.")
                }
                .onChange(of: confirmingDeleteProfile) { _, isPresented in
                    if !isPresented {
                        deleteCredentialWithProfile = false
                    }
                }
                .onChange(of: profile.name) { _, _ in
                    deleteCredentialWithProfile = false
                }
            } else {
                ContentUnavailableView("Select a Proxy Profile", systemImage: "point.3.connected.trianglepath.dotted")
                    .padding(24)
            }
        }
    }
}

struct MCPProfilesView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        ManagementPageFrame(title: "MCP", subtitle: "Pinned upstream profiles for authorization injection.") {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.mcpProfiles.isEmpty {
                PageCenteredState {
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
            } else {
                HSplitView {
                    List(selection: $store.selectedMCPProfile) {
                        ForEach(store.mcpProfiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.headline)
                                Text(profile.origin.host() ?? profile.origin.absoluteString)
                                    .foregroundStyle(.secondary)
                                Text(profile.allowedPathPrefixes.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .tag(Optional(profile.name))
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    MCPProfileDetail(store: store)
                        .frame(minWidth: 480)
                }
                .frame(minHeight: 420)
            }
        }
    }
}

private struct MCPProfileDetail: View {
    @Bindable var store: ManagementStore
    @State private var showingEdit = false
    @State private var confirmingDelete = false
    @State private var validationMessage: String?

    var body: some View {
        ScrollView {
            if let profile = store.selectedMCPProfileSummary {
                VStack(alignment: .leading, spacing: 18) {
                    header(profile.name, subtitle: profile.origin.absoluteString)
                    Form {
                        Section("Configuration") {
                            LabeledContent("Authorization header", value: profile.authorizationHeaderName)
                            LabeledContent("Path prefixes", value: profile.allowedPathPrefixes.joined(separator: ", "))
                            LabeledContent("Cross-origin redirects", value: profile.allowCrossOriginRedirects ? "Allowed" : "Blocked")
                            Button {
                                showingEdit = true
                            } label: {
                                Label("Edit MCP Profile", systemImage: "slider.horizontal.3")
                            }
                            .disabled(!store.canManageCoreState)
                        }
                        Section("Client Setup") {
                            CopyableValueView(title: "Profile origin", value: profile.origin.absoluteString)
                            CopyButton(
                                title: "Copy MCP Client Config",
                                value: mcpClientConfig(profile),
                                help: "Copy redacted MCP client configuration for this profile"
                            )
                        }
                        Section("Credential") {
                            StatusBadge(text: "No stored credential alias", systemImage: "key.slash")
                            Text("This MCP profile defines where authorization can be injected, but it does not currently bind a saved secret alias. Edit the profile if the upstream authorization metadata changes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Section("Trust") {
                            StatusBadge(text: "Pinned origin", systemImage: "pin")
                            Button {
                                validationMessage = validate(profile: profile)
                            } label: {
                                Label("Validate Profile", systemImage: "checkmark.shield")
                            }
                            .help("Validate the pinned origin and allowed path configuration locally")
                            if let validationMessage {
                                Text(validationMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section("Danger Zone") {
                            Button("Delete Profile", role: .destructive) {
                                confirmingDelete = true
                            }
                            .disabled(!store.canManageCoreState)
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .sheet(isPresented: $showingEdit) {
                    MCPProfileEditor(store: store, profile: profile)
                }
                .confirmationDialog("Delete MCP profile?", isPresented: $confirmingDelete) {
                    Button("Delete Profile", role: .destructive) {
                        Task { await store.deleteMCPProfile(name: profile.name) }
                    }
                    .disabled(!store.canManageCoreState)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The pinned MCP upstream profile is removed from local configuration.")
                }
            } else {
                ContentUnavailableView("Select an MCP Profile", systemImage: "server.rack")
                    .padding(24)
            }
        }
    }

    private func validate(profile: MCPProfileSummary) -> String {
        guard profile.origin.scheme == "https", profile.origin.host()?.isEmpty == false else {
            return "Profile needs an HTTPS origin with a host."
        }
        guard !profile.allowedPathPrefixes.isEmpty else {
            return "Profile needs at least one allowed path prefix."
        }
        return "Profile shape is valid. Network verification is intentionally explicit and not run automatically."
    }

    private func mcpClientConfig(_ profile: MCPProfileSummary) -> String {
        """
        {
          "name": "\(profile.name)",
          "origin": "\(profile.origin.absoluteString)",
          "authorizationHeader": "\(profile.authorizationHeaderName)",
          "allowedPathPrefixes": \(jsonStringArray(profile.allowedPathPrefixes)),
          "allowCrossOriginRedirects": \(profile.allowCrossOriginRedirects),
          "credential": "managed-by-agentic-fortress"
        }
        """
    }
}

struct BWSView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        ManagementPageFrame(title: "BWS", subtitle: "External secret provider bindings, without exposing fetched values.") {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.bwsBindings.isEmpty {
                PageCenteredState {
                    ContentUnavailableView {
                        Label("No BWS Bindings", systemImage: "key.horizontal")
                    } description: {
                        Text("Create a binding to authorize one exact BWS secret per invocation.")
                    } actions: {
                        Button {
                            store.presentBWSBindingEditor()
                        } label: {
                            Label("Create BWS Binding", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canManageCoreState)
                        .help("Create a Bitwarden Secrets Manager binding")
                        Button {
                            store.presentDiagnostics()
                        } label: {
                            Label("Review Diagnostics", systemImage: "stethoscope")
                        }
                        .buttonStyle(.bordered)
                        .help("Review local core and provider setup")
                    }
                }
            } else {
                HSplitView {
                    List(selection: $store.selectedBWSBinding) {
                        ForEach(store.bwsBindings) { binding in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(binding.alias).font(.headline)
                                Text("\(binding.environment) · \(binding.requiresPerFetchApproval ? "approval required" : "\(Int(binding.maxLeaseSeconds))s lease")")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(binding.secretIDDigest)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 4)
                            .tag(Optional(binding.alias))
                        }
                    }
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
                    BWSBindingDetail(store: store)
                        .frame(minWidth: 460)
                }
                .frame(minHeight: 420)
            }
        }
    }
}

private struct BWSBindingDetail: View {
    @Bindable var store: ManagementStore
    @State private var showingEdit = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            if let binding = store.selectedBWSBindingSummary {
                VStack(alignment: .leading, spacing: 18) {
                    header(binding.alias, subtitle: "Bitwarden Secrets Manager binding")
                    Form {
                        Section("Binding") {
                            LabeledContent("Project ID", value: binding.projectID)
                            LabeledContent("Environment", value: binding.environment)
                            LabeledContent("Secret ID digest", value: binding.secretIDDigest)
                            HStack {
                                Button {
                                    showingEdit = true
                                } label: {
                                    Label("Replace Binding", systemImage: "slider.horizontal.3")
                                }
                                .disabled(!store.canManageCoreState)
                                .help("Update binding metadata and provide the write-only BWS secret ID again")
                                Button {
                                    ExternalURLOpener.open(
                                        URL(string: "https://vault.bitwarden.com/#/sm/secrets")!,
                                        label: "Bitwarden Secrets Manager",
                                        store: store
                                    )
                                } label: {
                                    Label("Open Bitwarden", systemImage: "arrow.up.right.square")
                                }
                                CopyButton(
                                    title: "Copy Reference",
                                    value: bwsBindingReference(binding),
                                    help: "Copy a redacted binding reference"
                                )
                            }
                        }
                        Section("Runtime Policy") {
                            LabeledContent("Max lease", value: binding.requiresPerFetchApproval ? "Per fetch approval" : "\(Int(binding.maxLeaseSeconds))s")
                            LabeledContent("Secret values", value: "Never shown in UI")
                        }
                        Section("Danger Zone") {
                            Button("Delete Binding", role: .destructive) {
                                confirmingDelete = true
                            }
                            .disabled(!store.canManageCoreState)
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .sheet(isPresented: $showingEdit) {
                    BWSBindingEditor(store: store, binding: binding)
                }
                .confirmationDialog("Delete BWS binding?", isPresented: $confirmingDelete) {
                    Button("Delete Binding", role: .destructive) {
                        Task { await store.deleteBWSBinding(alias: binding.alias) }
                    }
                    .disabled(!store.canManageCoreState)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the local binding metadata. It does not delete any upstream Bitwarden secret.")
                }
            } else {
                ContentUnavailableView("Select a BWS Binding", systemImage: "key.horizontal")
                    .padding(24)
            }
        }
    }

    private func bwsBindingReference(_ binding: BWSBindingSummary) -> String {
        """
        alias: \(binding.alias)
        provider: bitwarden-secrets-manager
        projectID: \(binding.projectID)
        secretIDDigest: \(binding.secretIDDigest)
        environment: \(binding.environment)
        """
    }
}

struct AdaptersView: View {
    @Bindable var store: ManagementStore
    @State private var confirmingRevoke = false

    var body: some View {
        ManagementPageFrame(
            title: "Adapters",
            subtitle: "Signed command-classification packs. CLIs use adapters; adapters are not secrets."
        ) {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.adapters.isEmpty {
                PageCenteredState {
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
            } else {
                HSplitView {
                    Table(store.adapters, selection: $store.selectedAdapter) {
                        TableColumn("CLI", value: \.cliName)
                        TableColumn("Publisher", value: \.publisher)
                        TableColumn("Version") { Text("\($0.adapterVersion)") }
                        TableColumn("Rules") { Text("\($0.ruleCount)") }
                    }
                    .frame(minWidth: 440)
                    AdapterDetail(store: store, confirmingRevoke: $confirmingRevoke)
                        .frame(minWidth: 380)
                }
                .frame(minHeight: 440)
            }
        }
        .confirmationDialog("Revoke adapter?", isPresented: $confirmingRevoke) {
            if let adapter = store.selectedAdapterSummary {
                Button("Revoke Adapter", role: .destructive) {
                    Task { await store.revokeAdapter(adapterID: adapter.adapterID) }
                }
                .disabled(!store.canManageCoreState || adapter.revokedAt != nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Revoked adapters no longer classify commands. Built-in adapters may reappear from the bundled registry.")
        }
    }
}

private struct AdapterDetail: View {
    @Bindable var store: ManagementStore
    @Binding var confirmingRevoke: Bool
    @State private var showingManifest = false

    var body: some View {
        ScrollView {
            if let adapter = store.selectedAdapterSummary {
                VStack(alignment: .leading, spacing: 18) {
                    header(adapter.cliName, subtitle: adapter.adapterID)
                    Form {
                        Section("Manifest") {
                            LabeledContent("Publisher", value: adapter.publisher)
                            LabeledContent("Version", value: "\(adapter.adapterVersion)")
                            LabeledContent("Rules", value: "\(adapter.ruleCount)")
                            LabeledContent("Hash", value: adapter.adapterHash)
                            if let installedAt = adapter.installedAt {
                                LabeledContent("Installed", value: installedAt.formatted())
                            }
                        }
                        Section("Trust") {
                            StatusBadge(text: adapter.revokedAt == nil ? "Active" : "Revoked", systemImage: adapter.revokedAt == nil ? "checkmark.shield" : "xmark.shield")
                            HStack {
                                Button {
                                    showingManifest = true
                                } label: {
                                    Label("View Manifest", systemImage: "doc.text.magnifyingglass")
                                }
                                .help("View installed adapter manifest metadata")
                                CopyButton(
                                    title: "Copy Report",
                                    value: adapterReport(adapter),
                                    help: "Copy a redacted adapter report"
                                )
                            }
                        }
                        Section("Affected CLIs") {
                            Text(adapter.cliName)
                            Button("Open CLI Registration") {
                                store.selectedSection = .cliSecrets
                                store.selectedCLI = adapter.cliName
                            }
                            .disabled(store.snapshot?.cliRegistrations.contains(where: { $0.name == adapter.cliName }) != true)
                        }
                        Section("Danger Zone") {
                            Button("Revoke Adapter", role: .destructive) {
                                confirmingRevoke = true
                            }
                            .disabled(!store.canManageCoreState || adapter.revokedAt != nil)
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .sheet(isPresented: $showingManifest) {
                    AdapterManifestView(adapter: adapter)
                }
            } else {
                ContentUnavailableView("Select an Adapter", systemImage: "puzzlepiece.extension")
                    .padding(24)
            }
        }
    }

    private func adapterReport(_ adapter: AdapterSummary) -> String {
        """
        adapterID: \(adapter.adapterID)
        cli: \(adapter.cliName)
        publisher: \(adapter.publisher)
        version: \(adapter.adapterVersion)
        rules: \(adapter.ruleCount)
        hash: \(adapter.adapterHash)
        status: \(adapter.revokedAt == nil ? "active" : "revoked")
        """
    }
}

private struct AdapterManifestView: View {
    @Environment(\.dismiss) private var dismiss
    var adapter: AdapterSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Adapter Manifest", subtitle: adapter.adapterID)
            Form {
                Section("Identity") {
                    LabeledContent("CLI", value: adapter.cliName)
                    LabeledContent("Publisher", value: adapter.publisher)
                    LabeledContent("Version", value: "\(adapter.adapterVersion)")
                    LabeledContent("Rules", value: "\(adapter.ruleCount)")
                }
                Section("Integrity") {
                    LabeledContent("Hash", value: adapter.adapterHash)
                    LabeledContent("Status", value: adapter.revokedAt == nil ? "Active" : "Revoked")
                    Text("The management summary exposes hash, publisher, and version. Signed payload verification happens before install in core.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding()
    }
}

struct AuditView: View {
    @Bindable var store: ManagementStore
    @State private var selectedEventID: AuditEventSummary.ID?
    @State private var filterText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                header("Audit", subtitle: "Redacted events only")
                Spacer()
                CopyButton(title: "Copy Event", value: redactedEventText(selectedEvent), help: "Copy selected redacted audit event")
                .disabled(selectedEvent == nil)
                .help(selectedEvent == nil ? "Select an audit event first" : "Copy selected redacted audit event")

                Button {
                    openRelatedItem(selectedEvent)
                } label: {
                    Label("Open Related Item", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(relatedItemTitle(for: selectedEvent) == nil)
                .help(relatedItemTitle(for: selectedEvent) ?? "Select an event with a related local item")

                Button("Export Redacted JSON") {
                    AuditExportWriter.export(store: store)
                }
                .disabled(!store.canExportAudit)
                .help(store.canExportAudit ? "Save all redacted audit events as a JSON file" : "Load local state before exporting audit")
            }
            HStack {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Decision, flow, subject, alias, action, outcome", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Audit filter")
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Label("Clear Filter", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear audit filter")
                }
            }
            Table(filteredEvents, selection: $selectedEventID) {
                TableColumn("Time") { Text($0.time, style: .time) }
                TableColumn("Decision", value: \.decision)
                TableColumn("Flow") { Text($0.flow.rawValue) }
                TableColumn("Subject", value: \.subjectID)
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
                } else if filteredEvents.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Audit Events", systemImage: "magnifyingglass")
                    } description: {
                        Text("No redacted event matches this filter.")
                    } actions: {
                        Button {
                            filterText = ""
                        } label: {
                            Label("Clear Filter", systemImage: "xmark.circle")
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

    private var allEvents: [AuditEventSummary] {
        store.snapshot?.auditEvents ?? []
    }

    private var filteredEvents: [AuditEventSummary] {
        AuditEventFilter.filtered(allEvents, query: filterText)
    }

    private var selectedEvent: AuditEventSummary? {
        AuditEventFilter.selectedVisibleEvent(selectedID: selectedEventID, visibleEvents: filteredEvents)
    }

    private func redactedEventText(_ event: AuditEventSummary?) -> String {
        guard let event else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) else {
            return "\(event.time.formatted()) \(event.flow.rawValue) \(event.subjectID) \(event.outcome)"
        }
        return text
    }

    private func relatedItemTitle(for event: AuditEventSummary?) -> String? {
        AuditRelatedItemRouter.route(for: event, snapshot: store.snapshot)?.title
    }

    private func openRelatedItem(_ event: AuditEventSummary?) {
        guard let route = AuditRelatedItemRouter.route(for: event, snapshot: store.snapshot) else { return }
        switch route {
        case .cli(let name):
            store.selectedSection = .cliSecrets
            store.selectedCLI = name
        case .proxy(let name):
            store.selectedSection = .proxy
            store.selectedProxyProfile = name
        case .bws(let alias):
            store.selectedSection = .bws
            store.selectedBWSBinding = alias
        case .mcp(let name):
            store.selectedSection = .mcp
            store.selectedMCPProfile = name
        }
    }
}

struct DiagnosticsView: View {
    @Bindable var store: ManagementStore
    @State private var confirmingInstall = false

    var body: some View {
        Form {
            Section("Daemon") {
                DaemonRecommendedFixPanel(store: store, confirmingInstall: $confirmingInstall)
                LabeledContent("Status", value: store.daemonStatus.state.rawValue.capitalized)
                LabeledContent("Socket", value: store.daemonStatus.socketPath)
                LabeledContent("LaunchAgent", value: store.daemonStatus.launchAgentPath ?? "Not installed")
                Text(store.daemonStatus.message)
                    .foregroundStyle(store.daemonStatus.state == .healthy ? .secondary : .primary)
                DisclosureGroup("Advanced diagnostics") {
                    HStack {
                        DaemonActionButtons(
                            store: store,
                            confirmingInstall: $confirmingInstall,
                            includeAdvancedActions: true,
                            includeBestAction: false
                        )
                    }
                    if let detail = store.daemonStatus.detail {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let plan = store.daemonInstallPlan {
                        Divider()
                        DaemonInstallPlanView(store: store, plan: plan)
                    }
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

struct DaemonRecommendedFixPanel: View {
    @Bindable var store: ManagementStore
    @Binding var confirmingInstall: Bool

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
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = store.bestDaemonAction {
                Button {
                    perform(action)
                } label: {
                    Label(action.title(plan: store.daemonInstallPlan), systemImage: action.systemImage)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDisabled(action))
                .accessibilityLabel(action.title(plan: store.daemonInstallPlan))
                .help(help(for: action))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        switch store.daemonStatus.state {
        case .healthy:
            "Setup Ready"
        case .installing:
            "Installing Local Daemon"
        case .repairing:
            "Repairing Local Daemon"
        case .unknown, .unavailable:
            "Recommended Fix"
        }
    }

    private var symbol: String {
        switch store.daemonStatus.state {
        case .healthy:
            "checkmark.circle"
        case .installing:
            "tray.and.arrow.down"
        case .repairing:
            "arrow.clockwise"
        case .unknown:
            "questionmark.circle"
        case .unavailable:
            "wrench.and.screwdriver"
        }
    }

    private var message: String {
        guard let action = store.bestDaemonAction else {
            return "The local daemon is reachable. Management actions can use the authenticated local control plane."
        }
        switch action {
        case .check:
            return store.daemonInstallPlan?.summary ?? "Check the local daemon and install state before continuing."
        case .installOrRepair:
            return "Install or repair the local daemon, helper links, authenticated install manifest, and per-user LaunchAgent. Secret material is not read or moved."
        case .restart:
            return "The LaunchAgent exists but the daemon is not reachable. Restart the local daemon and then refresh state."
        case .openInstalledApp:
            return "This window is running from a different app copy than the one trusted by the local install. Open the installed copy so the daemon can authenticate the UI."
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
            return !store.canOpenInstalledApp
        }
    }

    private func help(for action: DaemonNextAction) -> String {
        switch action {
        case .check:
            "Recheck daemon status and local install files"
        case .installOrRepair:
            "Install or repair the local daemon without reading secret material"
        case .restart:
            "Restart the per-user local daemon"
        case .openInstalledApp:
            "Open the installed copy used by the authenticated local install"
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
            InstalledAppOpener.open(store: store)
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
        PageCenteredState {
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
    var includeBestAction = true

    var body: some View {
        HStack(spacing: 8) {
            ForEach(visibleActions, id: \.self) { action in
                actionButton(action, prominent: action == store.bestDaemonAction)
            }
        }
    }

    private var visibleActions: [DaemonNextAction] {
        var actions: [DaemonNextAction] = []
        if includeBestAction, let best = store.bestDaemonAction {
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
            return store.daemonStatus.state != .healthy && (store.daemonInstallPlan?.canInstall ?? false)
        case .restart:
            return store.daemonStatus.state != .healthy && store.daemonStatus.canRepair
        case .openInstalledApp:
            guard store.daemonInstallPlan?.currentAppIsInstalledCopy == false else { return false }
            return store.canOpenInstalledApp
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
            return !store.canOpenInstalledApp
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
            InstalledAppOpener.open(store: store)
        }
    }
}

struct DaemonInstallPlanView: View {
    var store: ManagementStore
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
                    LocalFileOpener.openDirectory(path: plan.prefixPath, label: "install folder", store: store)
                }
                .disabled(!LocalFileOpener.fileExists(atPath: plan.prefixPath))
                Button("Open Installed Copy") {
                    InstalledAppOpener.open(store: store)
                }
                .disabled(!store.canOpenInstalledApp)
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

struct ManagementPageFrame<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(title, subtitle: subtitle)
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PageCenteredState<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(minHeight: 420)
    }
}

struct CopyableValueView: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
                CopyButton(value: value, help: "Copy \(title)")
            }
        }
    }
}

func jsonStringArray(_ values: [String]) -> String {
    let escaped = values.map { value in
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    return "[" + escaped.joined(separator: ", ") + "]"
}

func header(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.largeTitle.bold())
        Text(subtitle).foregroundStyle(.secondary)
    }
}
