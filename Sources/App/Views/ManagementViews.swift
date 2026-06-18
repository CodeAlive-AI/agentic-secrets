import AgenticSecretsBroker
import AppKit
import SwiftUI

struct OverviewView: View {
    var store: ControlPlaneStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header("Overview", subtitle: store.snapshot?.stateDirectory ?? "Loading local state")
                BrokerStatusPanel(store: store)
                if let snapshot = store.snapshot {
                    if snapshot.cliRegistrations.isEmpty {
                        FirstRunOverviewPanel(store: store)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                        MetricTile(title: "CLIs", value: "\(snapshot.cliRegistrations.count)", systemImage: "terminal")
                        MetricTile(title: "Secrets", value: "\(snapshot.secrets.count)", systemImage: "key")
                        MetricTile(title: "Grants", value: "\(snapshot.deliveryGrants.count)", systemImage: "timer")
                        MetricTile(title: "Audit", value: "\(snapshot.auditEvents.count)", systemImage: "list.bullet.clipboard")
                    }
                    StatusPanel(health: snapshot.securityHealth)
                    RecentActivityList(events: Array(snapshot.auditEvents.prefix(6)))
                } else {
                    SnapshotUnavailablePanel(store: store)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1180, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct FirstRunOverviewPanel: View {
    var store: ControlPlaneStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Protect Your First CLI", systemImage: "terminal")
                .font(.headline)
            Text("Agentic Secrets keeps tokens out of shell profiles, .env files, and plaintext tool configs. Start by registering the CLI executable that should receive one approved secret at runtime.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                store.presentRegisterCLI()
            } label: {
                Label("Register CLI", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canRegisterCLI)
            .accessibilityLabel("Register CLI")
            .help("Start the CLI registration wizard")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CLISecretsView: View {
    @Bindable var store: ControlPlaneStore
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
            .disabled(!store.canManageBrokerState)
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
    @Bindable var store: ControlPlaneStore

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
    @Bindable var store: ControlPlaneStore
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
                                .disabled(!store.canManageBrokerState)
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
                                .disabled(!store.canManageBrokerState)
                                .help("Install or repair the local command shim for this CLI")
                                Button("Remove Shim", role: .destructive) {
                                    pendingShimRemoval = cli
                                }
                                .disabled(!store.canManageBrokerState)
                                .help("Remove the local command shim for this CLI")
                            }
                            Text("A shim routes normal \(cli.name) invocations through Agentic Secrets when the local shims folder is before the native CLI on PATH.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Section("Grants") {
                            LabeledContent("Active grants", value: "\(store.snapshot?.deliveryGrants.count ?? 0)")
                            Button {
                                Task { await store.clearDeliveryGrants() }
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
                            .disabled(!store.canManageBrokerState)
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
            .disabled(!store.canManageBrokerState)
            Button("Cancel", role: .cancel) {
                pendingShimRemoval = nil
            }
        } message: {
            Text("Normal \(pendingShimRemoval?.name ?? "CLI") invocations will stop routing through Agentic Secrets until the shim is installed again.")
        }
    }
}

private struct NoCLIRegistrationsView: View {
    @Bindable var store: ControlPlaneStore

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
    @Bindable var store: ControlPlaneStore

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
    @Bindable var store: ControlPlaneStore
    var binding: EnvironmentSecretBinding
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
                .disabled(!store.canManageBrokerState)
                .help(store.canManageBrokerState ? "Replace write-only secret material" : "Repair the daemon before replacing secret material")
            Button("Delete", role: .destructive) { showingDelete = true }
                .disabled(!store.canManageBrokerState)
                .help(store.canManageBrokerState ? "Delete write-only secret material" : "Repair the daemon before deleting secret material")
        }
        .sheet(isPresented: $showingReplace) {
            ReplaceSecretView(store: store, alias: binding.secretAlias, label: "\(cliName) \(binding.environmentName)", environment: "cli:\(cliName)")
        }
        .confirmationDialog("Delete secret material?", isPresented: $showingDelete) {
            Button("Delete Secret Material", role: .destructive) {
                Task { await store.deleteSecret(alias: binding.secretAlias) }
            }
            .disabled(!store.canManageBrokerState)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes encrypted local material for \(binding.secretAlias). The value cannot be revealed first.")
        }
    }
}

struct APISessionProfilesView: View {
    @Bindable var store: ControlPlaneStore

    var body: some View {
        ControlPlanePageFrame(
            title: "API Sessions (Proxy)",
            subtitle: "Bounded localhost sessions that keep upstream API keys out of client apps."
        ) {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.apiSessionProfiles.isEmpty {
                PageCenteredState {
                    ContentUnavailableView {
                        Label("No API Session Profiles", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Create a bounded localhost API session profile before starting API sessions.")
                    } actions: {
                        Button {
                            store.presentAPISessionProfileEditor()
                        } label: {
                            Label("Add API Session Profile", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canManageBrokerState)
                    }
                }
            } else {
                HSplitView {
                    List(selection: $store.selectedAPISessionProfile) {
                        ForEach(store.apiSessionProfiles) { profile in
                            APISessionProfileRow(profile: profile)
                                .tag(Optional(profile.name))
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

                    APISessionProfileDetail(store: store)
                        .frame(minWidth: 480)
                }
                .frame(minHeight: 440)
            }
        }
    }
}

private struct APISessionProfileRow: View {
    var profile: APISessionProfileSummary

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
        .accessibilityLabel("API session profile \(profile.name)")
    }
}

private struct APISessionProfileDetail: View {
    @Bindable var store: ControlPlaneStore
    @State private var bindPort = 48177
    @State private var showingEdit = false
    @State private var showingReplaceSecret = false
    @State private var confirmingDeleteSecret = false
    @State private var confirmingDeleteProfile = false
    @State private var deleteCredentialWithProfile = false

    var body: some View {
        ScrollView {
            if let profile = store.selectedAPISessionProfileSummary {
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
                            .disabled(!store.canManageBrokerState)
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
                                .disabled(!store.canManageBrokerState)
                                .help("Write a replacement upstream API key. The saved value is never shown.")
                                Button("Delete API Key", role: .destructive) {
                                    confirmingDeleteSecret = true
                                }
                                .disabled(!store.canManageBrokerState)
                                .help("Delete stored credential material for this API session alias")
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
                            .help("Local port for the next API session")
                            Button {
                                Task { await store.createAPISession(profileName: profile.name, bindPort: bindPort) }
                            } label: {
                                Label("Create Session", systemImage: "bolt.horizontal")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canManageBrokerState)
                            .help("Create a one-time localhost API session for this profile")
                            if let endpoint = store.selectedAPISession?.endpoint {
                                CopyableValueView(title: "API Session URL", value: endpoint.absoluteString)
                            }
                            if let token = store.selectedAPISession?.token {
                                CopyableSecretOnceView(title: "One-time API session token", value: token)
                                Button {
                                    store.clearAPISession(profileName: profile.name)
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
                            .disabled(!store.canManageBrokerState)
                            .help("Remove this API session profile. Credential material is kept unless the checkbox is selected.")
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .sheet(isPresented: $showingEdit) {
                    APISessionProfileEditor(store: store, profile: profile)
                }
                .sheet(isPresented: $showingReplaceSecret) {
                    ReplaceSecretView(store: store, alias: profile.secretAlias, label: "\(profile.name) API session API key", environment: "api-session:\(profile.name)")
                }
                .confirmationDialog("Delete API key?", isPresented: $confirmingDeleteSecret) {
                    Button("Delete API Key", role: .destructive) {
                        Task { await store.deleteSecret(alias: profile.secretAlias) }
                    }
                    .disabled(!store.canManageBrokerState)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes local encrypted material for \(profile.secretAlias). The saved value cannot be displayed first.")
                }
                .confirmationDialog("Delete API session profile?", isPresented: $confirmingDeleteProfile) {
                    Button("Delete Profile", role: .destructive) {
                        let shouldDeleteCredential = deleteCredentialWithProfile
                        deleteCredentialWithProfile = false
                        Task {
                            await store.deleteAPISessionProfile(
                                name: profile.name,
                                deleteSecretAlias: shouldDeleteCredential ? profile.secretAlias : nil
                            )
                        }
                    }
                    .disabled(!store.canManageBrokerState)
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
                ContentUnavailableView("Select an API Session Profile", systemImage: "point.3.connected.trianglepath.dotted")
                    .padding(24)
            }
        }
    }
}

struct MCPProfilesView: View {
    @Bindable var store: ControlPlaneStore

    var body: some View {
        ControlPlanePageFrame(title: "MCP Proxy", subtitle: "Pinned upstream proxy profiles for authorization injection.") {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.mcpProfiles.isEmpty {
                PageCenteredState {
                    ContentUnavailableView {
                        Label("No MCP Proxy Profiles", systemImage: "server.rack")
                    } description: {
                        Text("Pinned MCP proxy upstreams keep authorization injection bounded.")
                    } actions: {
                        Button {
                            store.presentMCPProfileEditor()
                        } label: {
                            Label("Add MCP Proxy", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canManageBrokerState)
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
    @Bindable var store: ControlPlaneStore
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
                            LabeledContent("Original URL", value: profile.origin.absoluteString)
                            LabeledContent("Auth header", value: profile.authorizationHeaderName)
                            Button {
                                showingEdit = true
                            } label: {
                                Label("Edit MCP Proxy", systemImage: "slider.horizontal.3")
                            }
                            .disabled(!store.canManageBrokerState)
                        }
                        Section("Client Setup") {
                            CopyableValueView(title: "Original URL", value: profile.origin.absoluteString)
                            CopyButton(
                                title: "Copy MCP Proxy Client Config",
                                value: mcpClientConfig(profile),
                                help: "Copy redacted MCP proxy client configuration for this profile"
                            )
                        }
                        Section("Credential") {
                            if let secretAlias = profile.secretAlias, !secretAlias.isEmpty {
                                StatusBadge(text: "Uses managed secret alias", systemImage: "key")
                                CopyableValueView(title: "Secret alias", value: secretAlias)
                            } else {
                                StatusBadge(text: "No token secret alias", systemImage: "key.slash")
                            }
                            Text("The proxy stores only the secret alias. The token value is resolved by Agentic Secrets and injected only into approved upstream requests.")
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
                            Button("Delete MCP Proxy", role: .destructive) {
                                confirmingDelete = true
                            }
                            .disabled(!store.canManageBrokerState)
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .sheet(isPresented: $showingEdit) {
                    MCPProfileEditor(store: store, profile: profile)
                }
                .confirmationDialog("Delete MCP proxy?", isPresented: $confirmingDelete) {
                    Button("Delete MCP Proxy", role: .destructive) {
                        Task { await store.deleteMCPProfile(name: profile.name) }
                    }
                    .disabled(!store.canManageBrokerState)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The pinned MCP proxy profile is removed from local configuration.")
                }
            } else {
                ContentUnavailableView("Select an MCP Proxy", systemImage: "server.rack")
                    .padding(24)
            }
        }
    }

    private func validate(profile: MCPProfileSummary) -> String {
        guard profile.origin.scheme == "https", profile.origin.host()?.isEmpty == false else {
            return "MCP Proxy needs an HTTPS original URL with a host."
        }
        guard profile.secretAlias?.isEmpty == false else {
            return "MCP Proxy needs a saved auth value."
        }
        return "MCP Proxy shape is valid. Network verification is intentionally explicit and not run automatically."
    }

    private func mcpClientConfig(_ profile: MCPProfileSummary) -> String {
        """
        {
          "name": "\(profile.name)",
          "originalUrl": "\(profile.origin.absoluteString)",
          "authHeader": "\(profile.authorizationHeaderName)",
          "credential": "managed-by-agentic-secrets"
        }
        """
    }
}

struct BitwardenProviderBindingsView: View {
    @Bindable var store: ControlPlaneStore

    var body: some View {
        ControlPlanePageFrame(title: "Bitwarden Secrets", subtitle: "Bitwarden Secrets Manager bindings, without exposing fetched values.") {
            BitwardenPreviewNotice()
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.bitwardenBindings.isEmpty {
                PageCenteredState {
                    ContentUnavailableView {
                        Label("No Bitwarden Secrets", systemImage: "key.horizontal")
                    } description: {
                        Text("Create a binding to authorize one exact Bitwarden secret per invocation.")
                    } actions: {
                        Button {
                            store.presentBitwardenBindingEditor()
                        } label: {
                            Label("Create Bitwarden Provider Binding", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canManageBrokerState)
                        .help("Create a Bitwarden Secrets Manager binding")
                        Button {
                            store.presentDiagnostics()
                        } label: {
                            Label("Review Diagnostic & Uninstall", systemImage: "stethoscope")
                        }
                        .buttonStyle(.bordered)
                        .help("Review local broker and provider setup")
                    }
                }
            } else {
                HSplitView {
                    List(selection: $store.selectedBitwardenBinding) {
                        ForEach(store.bitwardenBindings) { binding in
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
                    BitwardenBindingDetail(store: store)
                        .frame(minWidth: 460)
                }
                .frame(minHeight: 420)
            }
        }
    }
}

private struct BitwardenPreviewNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hourglass.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("Preview Feature")
                    .font(.headline)
                Text("Bitwarden integration is available for early testing, but the setup flow and end-to-end coverage are not finished yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct BitwardenBindingDetail: View {
    @Bindable var store: ControlPlaneStore
    @State private var showingEdit = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            if let binding = store.selectedBitwardenBindingSummary {
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
                                .disabled(!store.canManageBrokerState)
                                .help("Update binding metadata and provide the write-only Bitwarden secret ID again")
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
                                    value: bitwardenBindingReference(binding),
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
                            .disabled(!store.canManageBrokerState)
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .sheet(isPresented: $showingEdit) {
                    BitwardenBindingEditor(store: store, binding: binding)
                }
                .confirmationDialog("Delete Bitwarden provider binding?", isPresented: $confirmingDelete) {
                    Button("Delete Binding", role: .destructive) {
                        Task { await store.deleteBitwardenBinding(alias: binding.alias) }
                    }
                    .disabled(!store.canManageBrokerState)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the local binding metadata. It does not delete any upstream Bitwarden secret.")
                }
            } else {
                ContentUnavailableView("Select a Bitwarden Provider Binding", systemImage: "key.horizontal")
                    .padding(24)
            }
        }
    }

    private func bitwardenBindingReference(_ binding: BitwardenBindingSummary) -> String {
        """
        alias: \(binding.alias)
        provider: bitwarden-secrets-manager
        projectID: \(binding.projectID)
        secretIDDigest: \(binding.secretIDDigest)
        environment: \(binding.environment)
        """
    }
}

struct CommandPolicyPacksView: View {
    @Bindable var store: ControlPlaneStore
    @State private var confirmingRevoke = false

    var body: some View {
        ControlPlanePageFrame(
            title: "CLI Policy",
            subtitle: "Signed classifiers for CLI command risk. They do not register a CLI or store secrets."
        ) {
            if store.snapshot == nil {
                LocalStateUnavailableView(store: store)
            } else if store.policyPacks.isEmpty {
                PageCenteredState {
                    ContentUnavailableView {
                        Label("No CLI Policy Packs", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Install a signed command policy pack JSON payload to classify a supported CLI.")
                    } actions: {
                        Button {
                            CommandPolicyPackInstaller.presentOpenPanel(store: store)
                        } label: {
                            Label("Install Command Policy Pack", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canManageBrokerState)
                    }
                }
            } else {
                HSplitView {
                    Table(store.policyPacks, selection: $store.selectedAdapter) {
                        TableColumn("Policy Pack", value: \.policyPackID)
                        TableColumn("Applies To", value: \.cliName)
                        TableColumn("Source", value: \.source)
                        TableColumn("Status") { Text($0.revokedAt == nil ? "Active" : "Revoked") }
                        TableColumn("Publisher", value: \.publisher)
                    }
                    .frame(minWidth: 440)
                    AdapterDetail(store: store, confirmingRevoke: $confirmingRevoke)
                        .frame(minWidth: 380)
                }
                .frame(minHeight: 440)
            }
        }
        .confirmationDialog("Revoke adapter?", isPresented: $confirmingRevoke) {
            if let adapter = store.selectedPolicyPackSummary {
                Button("Revoke Adapter", role: .destructive) {
                    Task { await store.revokeAdapter(policyPackID: adapter.policyPackID) }
                }
                .disabled(!store.canManageBrokerState || adapter.revokedAt != nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Revoked policy packs no longer classify commands. Built-in revocations are recorded in local policy state.")
        }
    }
}

private struct AdapterDetail: View {
    @Bindable var store: ControlPlaneStore
    @Binding var confirmingRevoke: Bool
    @State private var showingManifest = false

    var body: some View {
        ScrollView {
            if let adapter = store.selectedPolicyPackSummary {
                VStack(alignment: .leading, spacing: 18) {
                    header(adapter.cliName, subtitle: adapter.policyPackID)
                    Form {
                        Section("Manifest") {
                            LabeledContent("Applies to CLI name", value: adapter.cliName)
                            LabeledContent("Source", value: adapter.source)
                            LabeledContent("Publisher", value: adapter.publisher)
                            LabeledContent("Version", value: "\(adapter.policyPackVersion)")
                            LabeledContent("Rules", value: "\(adapter.ruleCount)")
                            LabeledContent("Hash", value: adapter.policyPackHash)
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
                                .help("View installed command policy pack manifest metadata")
                                CopyButton(
                                    title: "Copy Report",
                                    value: policyPackReport(adapter),
                                    help: "Copy a redacted adapter report"
                                )
                            }
                        }
                        Section("Related CLI Delivery") {
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
                            .disabled(!store.canManageBrokerState || adapter.revokedAt != nil)
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

    private func policyPackReport(_ adapter: PolicyPackSummary) -> String {
        """
        policyPackID: \(adapter.policyPackID)
        source: \(adapter.source)
        appliesToCLIName: \(adapter.cliName)
        publisher: \(adapter.publisher)
        version: \(adapter.policyPackVersion)
        rules: \(adapter.ruleCount)
        hash: \(adapter.policyPackHash)
        status: \(adapter.revokedAt == nil ? "active" : "revoked")
        """
    }
}

private struct AdapterManifestView: View {
    @Environment(\.dismiss) private var dismiss
    var adapter: PolicyPackSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Command Policy Pack Manifest", subtitle: adapter.policyPackID)
            Form {
                Section("Identity") {
                    LabeledContent("CLI", value: adapter.cliName)
                    LabeledContent("Publisher", value: adapter.publisher)
                    LabeledContent("Version", value: "\(adapter.policyPackVersion)")
                    LabeledContent("Rules", value: "\(adapter.ruleCount)")
                }
                Section("Integrity") {
                    LabeledContent("Hash", value: adapter.policyPackHash)
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
    @Bindable var store: ControlPlaneStore
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
        case .bitwardenBinding(let alias):
            store.selectedSection = .bitwardenProviderBindings
            store.selectedBitwardenBinding = alias
        case .mcp(let name):
            store.selectedSection = .mcp
            store.selectedMCPProfile = name
        }
    }
}

struct DiagnosticsView: View {
    @Bindable var store: ControlPlaneStore
    @State private var confirmingInstall = false
    @State private var confirmingUninstall = false
    @State private var confirmingTotalDelete = false
    @State private var totalDeleteConfirmationText = ""
    @State private var totalDeleteInProgress = false

    var body: some View {
        Form {
            Section("Daemon") {
                BrokerRecommendedFixPanel(store: store, confirmingInstall: $confirmingInstall)
                LabeledContent("Status", value: store.brokerStatus.state.rawValue.capitalized)
                LabeledContent("Socket", value: store.brokerStatus.socketPath)
                LabeledContent("LaunchAgent", value: store.brokerStatus.launchAgentPath ?? "Not installed")
                Text(store.brokerStatus.message)
                    .foregroundStyle(store.brokerStatus.state == .healthy ? .secondary : .primary)
                DisclosureGroup("Advanced diagnostics") {
                    HStack {
                        BrokerActionButtons(
                            store: store,
                            confirmingInstall: $confirmingInstall,
                            includeAdvancedActions: true,
                            includeBestAction: false
                        )
                    }
                    if let detail = store.brokerStatus.detail {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let plan = store.brokerInstallPlan {
                        Divider()
                        BrokerInstallPlanView(store: store, plan: plan)
                    }
                }
            }
            Section("State") {
                LabeledContent("State directory", value: store.snapshot?.stateDirectory ?? "Unknown")
                LabeledContent("Config path", value: store.snapshot?.configPath ?? "Unknown")
            }
            Section("Removal") {
                if let plan = store.brokerUninstallPlan {
                    BrokerUninstallPlanView(plan: plan)
                }
                Button(role: .destructive) {
                    confirmingUninstall = true
                } label: {
                    Label("Uninstall Agentic Secrets", systemImage: "trash")
                }
                .disabled(!store.canUninstallLocalInstall)
                .help("Choose whether to keep local state or totally delete Agentic Secrets from this Mac")
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
            store.brokerInstallPlan?.primaryActionTitle ?? "Install Local Daemon",
            isPresented: $confirmingInstall,
            titleVisibility: .visible
        ) {
            Button(store.brokerInstallPlan?.primaryActionTitle ?? "Install Local Daemon") {
                Task { await store.installOrRepairDaemon() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agentic Secrets will update the local app in Applications, helper links, install manifest, and per-user LaunchAgent. Secret material is not read or moved.")
        }
        .confirmationDialog(
            "Uninstall Agentic Secrets?",
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Totally Delete Agentic Secrets", role: .destructive) {
                totalDeleteConfirmationText = ""
                confirmingTotalDelete = true
            }
            .disabled(!store.canUninstallLocalInstall)
            Button("Remove App, Keep Local State") {
                Task { @MainActor in
                    await performUninstall(purgeLocalState: false)
                }
            }
            .disabled(!store.canUninstallLocalInstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Totally Delete removes the local app, runtime files, command shims, helper links, the per-user LaunchAgent, managed shell PATH entries, local state, and known Agentic Secrets Keychain integrity sidecars. Secret values are never displayed.")
        }
        .sheet(isPresented: $confirmingTotalDelete) {
            TotalDeleteConfirmationSheet(
                confirmationText: $totalDeleteConfirmationText,
                isDeleting: totalDeleteInProgress,
                errorMessage: store.errorMessage,
                onCancel: {
                    confirmingTotalDelete = false
                    totalDeleteConfirmationText = ""
                },
                onConfirm: {
                    Task { @MainActor in
                        totalDeleteInProgress = true
                        let didUninstall = await store.uninstallLocalInstall(
                            purgeLocalState: true,
                            removeShellConfiguration: true
                        )
                        totalDeleteInProgress = false
                        if didUninstall {
                            confirmingTotalDelete = false
                            totalDeleteConfirmationText = ""
                            showUninstallCompleteAndTerminate(purgeLocalState: true)
                        }
                    }
                }
            )
        }
    }

    @MainActor
    private func performUninstall(purgeLocalState: Bool) async {
        let didUninstall = await store.uninstallLocalInstall(
            purgeLocalState: purgeLocalState,
            removeShellConfiguration: true
        )
        if didUninstall {
            showUninstallCompleteAndTerminate(purgeLocalState: purgeLocalState)
        }
    }

    @MainActor
    private func showUninstallCompleteAndTerminate(purgeLocalState: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = purgeLocalState ? "Agentic Secrets Was Totally Deleted" : "Agentic Secrets Was Removed"
        alert.informativeText = purgeLocalState
            ? "The local app, daemon, helper links, command shims, managed shell PATH entries, local state, and known Agentic Secrets Keychain integrity sidecars were removed. The app will now quit."
            : "The local app, daemon, helper links, command shims, and managed shell PATH entries were removed. Local Agentic Secrets state was kept. The app will now quit."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

private struct TotalDeleteConfirmationSheet: View {
    @Binding var confirmationText: String
    var isDeleting: Bool
    var errorMessage: String?
    var onCancel: () -> Void
    var onConfirm: () -> Void

    private var canConfirm: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines) == "delete" && !isDeleting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Totally Delete Agentic Secrets?", systemImage: "trash")
                .font(.title3.bold())
            Text("This is a full system removal. It removes the local app, daemon, helper links, command shims, managed shell PATH entries, local state, and known Agentic Secrets Keychain integrity sidecars. Secret values are never displayed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Type 'delete' to confirm")
                    .font(.headline)
                TextField("delete", text: $confirmationText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDeleting)
                    .accessibilityLabel("Type 'delete' to confirm total deletion")
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isDeleting)
                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Totally Delete and Quit", systemImage: "trash")
                    }
                }
                .disabled(!canConfirm)
                .help("Permanently remove Agentic Secrets and quit this app")
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

struct BrokerRecommendedFixPanel: View {
    @Bindable var store: ControlPlaneStore
    @Binding var confirmingInstall: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                if store.brokerStatus.state == .repairing || store.brokerStatus.state == .installing || store.brokerStatus.state == .uninstalling {
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
                    Label(action.title(plan: store.brokerInstallPlan), systemImage: action.systemImage)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDisabled(action))
                .accessibilityLabel(action.title(plan: store.brokerInstallPlan))
                .help(help(for: action))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .task(id: store.brokerStatus.state) {
            guard store.brokerStatus.state == .healthy, store.snapshot == nil, !store.isLoading else { return }
            await store.refresh()
        }
    }

    private var title: String {
        switch store.brokerStatus.state {
        case .healthy:
            "Setup Ready"
        case .installing:
            "Installing Local Daemon"
        case .repairing:
            "Repairing Local Daemon"
        case .uninstalling:
            "Removing Local Install"
        case .unknown, .unavailable:
            "Recommended Fix"
        }
    }

    private var symbol: String {
        switch store.brokerStatus.state {
        case .healthy:
            "checkmark.circle"
        case .installing:
            "tray.and.arrow.down"
        case .repairing:
            "arrow.clockwise"
        case .uninstalling:
            "trash"
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
            return store.brokerInstallPlan?.summary ?? "Check the local daemon and install state before continuing."
        case .installOrRepair:
            return "Install or repair the local app, daemon, helper links, authenticated install manifest, and per-user LaunchAgent. Secret material is not read or moved."
        case .restart:
            return "The LaunchAgent exists but the daemon is not reachable. Restart the local daemon and then refresh state."
        case .openInstalledApp:
            return "This window is running from a different app copy than the one trusted by the local install. Open the installed copy so the daemon can authenticate the UI."
        }
    }

    private func isDisabled(_ action: BrokerNextAction) -> Bool {
        if store.brokerStatus.state == .installing || store.brokerStatus.state == .repairing || store.brokerStatus.state == .uninstalling {
            return true
        }
        switch action {
        case .check:
            return store.isLoading
        case .installOrRepair:
            return !(store.brokerInstallPlan?.canInstall ?? false)
        case .restart:
            return !store.brokerStatus.canRepair
        case .openInstalledApp:
            return !store.canOpenInstalledApp
        }
    }

    private func help(for action: BrokerNextAction) -> String {
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

    private func perform(_ action: BrokerNextAction) {
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
    @Bindable var store: ControlPlaneStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
            if store.brokerStatus.state == .healthy {
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
        .task(id: store.brokerStatus.state) {
            guard store.brokerStatus.state == .healthy, store.snapshot == nil, !store.isLoading else { return }
            await store.refresh()
        }
    }

    private var title: String {
        if store.brokerStatus.state == .healthy, store.errorMessage != nil {
            return "Local State Load Failed"
        }
        return store.brokerStatus.state == .healthy ? "Local State Not Loaded" : "Local State Paused"
    }

    private var message: String {
        if store.brokerStatus.state == .healthy, let errorMessage = store.errorMessage {
            return errorMessage
        }
        return store.brokerStatus.state == .healthy
            ? "Refresh to load local Agentic Secrets state."
            : "Local state will load after the daemon is reachable."
    }

    private var symbol: String {
        store.brokerStatus.state == .healthy ? "shield" : "pause.circle"
    }
}

struct LocalStateUnavailableView: View {
    @Bindable var store: ControlPlaneStore
    @State private var confirmingInstall = false

    var body: some View {
        PageCenteredState {
            VStack(spacing: 14) {
                ContentUnavailableView {
                    Label(title, systemImage: symbol)
                } description: {
                    Text(message)
                } actions: {
                    VStack(spacing: 8) {
                        BrokerActionButtons(
                            store: store,
                            confirmingInstall: $confirmingInstall,
                            includeAdvancedActions: false
                        )
                        Button {
                            store.presentDiagnostics()
                        } label: {
                            Label("Open Diagnostic & Uninstall", systemImage: "stethoscope")
                        }
                        .buttonStyle(.bordered)
                        .help("Open daemon diagnostics, repair, and uninstall actions")
                    }
                }
            }
        }
        .confirmationDialog(
            store.brokerInstallPlan?.primaryActionTitle ?? "Install Local Daemon",
            isPresented: $confirmingInstall,
            titleVisibility: .visible
        ) {
            Button(store.brokerInstallPlan?.primaryActionTitle ?? "Install Local Daemon") {
                Task { await store.installOrRepairDaemon() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agentic Secrets will update the local app in Applications, helper links, install manifest, and per-user LaunchAgent. Secret material is not read or moved.")
        }
    }

    private var title: String {
        switch store.bestDaemonAction {
        case .openInstalledApp:
            "Open Installed Copy"
        case .restart:
            "Daemon Not Reachable"
        case .installOrRepair:
            "Local Daemon Needs Repair"
        case .check:
            "Daemon Status Unknown"
        case nil:
            store.brokerStatus.state == .healthy && store.errorMessage != nil
                ? "Local State Load Failed"
                : (store.brokerStatus.state == .healthy ? "Local State Not Loaded" : "Local State Unavailable")
        }
    }

    private var message: String {
        switch store.bestDaemonAction {
        case .openInstalledApp:
            "This window is not the app copy trusted by the local install. Open the installed copy to load local state."
        case .restart:
            "The LaunchAgent exists, but the local daemon is not reachable. Restart it, then refresh local state."
        case .installOrRepair:
            store.brokerInstallPlan?.summary ?? store.brokerStatus.message
        case .check:
            "Check daemon status and local install files before continuing."
        case nil:
            store.brokerStatus.state == .healthy && store.errorMessage != nil
                ? (store.errorMessage ?? "")
                : (store.brokerStatus.state == .healthy
                ? "Refresh to load local Agentic Secrets state."
                : store.brokerStatus.message)
        }
    }

    private var symbol: String {
        switch store.bestDaemonAction {
        case .openInstalledApp:
            "arrow.up.forward.app"
        case .restart:
            "restart"
        case .installOrRepair:
            "wrench.and.screwdriver"
        case .check:
            "questionmark.circle"
        case nil:
            store.brokerStatus.state == .healthy ? "shield" : "pause.circle"
        }
    }
}

struct BrokerStatusPanel: View {
    @Bindable var store: ControlPlaneStore
    @State private var confirmingInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                if store.brokerStatus.state == .repairing || store.brokerStatus.state == .installing || store.brokerStatus.state == .uninstalling {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(store.brokerStatus.message)
                .foregroundStyle(.secondary)
            BrokerActionButtons(store: store, confirmingInstall: $confirmingInstall, includeAdvancedActions: false)
            if let plan = store.brokerInstallPlan, !plan.canInstall {
                Text(plan.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog(
            store.brokerInstallPlan?.primaryActionTitle ?? "Install Local Daemon",
            isPresented: $confirmingInstall,
            titleVisibility: .visible
        ) {
            Button(store.brokerInstallPlan?.primaryActionTitle ?? "Install Local Daemon") {
                Task { await store.installOrRepairDaemon() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the local app in Applications, helper links, install manifest, and per-user LaunchAgent. Secret material is not read or moved.")
        }
    }

    private var title: String {
        switch store.brokerStatus.state {
        case .healthy: "Daemon Healthy"
        case .unavailable: "Daemon Unavailable"
        case .repairing: "Restarting Daemon"
        case .installing: "Installing Daemon"
        case .uninstalling: "Removing Install"
        case .unknown: "Daemon Status Unknown"
        }
    }

    private var symbol: String {
        switch store.brokerStatus.state {
        case .healthy: "checkmark.circle"
        case .unavailable: "exclamationmark.triangle"
        case .repairing: "arrow.clockwise"
        case .installing: "tray.and.arrow.down"
        case .uninstalling: "trash"
        case .unknown: "questionmark.circle"
        }
    }
}

struct BrokerActionButtons: View {
    @Bindable var store: ControlPlaneStore
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

    private var visibleActions: [BrokerNextAction] {
        var actions: [BrokerNextAction] = []
        if includeBestAction, let best = store.bestDaemonAction {
            actions.append(best)
        }

        if includeAdvancedActions {
            appendIfAvailable(.check, to: &actions)
            appendIfAvailable(.installOrRepair, to: &actions)
            appendIfAvailable(.restart, to: &actions)
            appendIfAvailable(.openInstalledApp, to: &actions)
        } else if store.brokerStatus.state != .healthy {
            appendIfAvailable(.check, to: &actions)
        } else {
            appendIfAvailable(.check, to: &actions)
        }
        return actions
    }

    private func appendIfAvailable(_ action: BrokerNextAction, to actions: inout [BrokerNextAction]) {
        guard !actions.contains(action), isAvailable(action) else { return }
        actions.append(action)
    }

    private func isAvailable(_ action: BrokerNextAction) -> Bool {
        switch action {
        case .check:
            return true
        case .installOrRepair:
            return store.brokerStatus.state != .healthy && (store.brokerInstallPlan?.canInstall ?? false)
        case .restart:
            return store.brokerStatus.state != .healthy && store.brokerStatus.canRepair
        case .openInstalledApp:
            guard store.brokerInstallPlan?.currentAppIsInstalledCopy == false else { return false }
            return store.canOpenInstalledApp
        }
    }

    private func isDisabled(_ action: BrokerNextAction) -> Bool {
        if store.brokerStatus.state == .installing || store.brokerStatus.state == .repairing || store.brokerStatus.state == .uninstalling {
            return true
        }
        switch action {
        case .check:
            return store.isLoading
        case .installOrRepair:
            return !(store.brokerInstallPlan?.canInstall ?? false)
        case .restart:
            return !store.brokerStatus.canRepair
        case .openInstalledApp:
            return !store.canOpenInstalledApp
        }
    }

    @ViewBuilder
    private func actionButton(_ action: BrokerNextAction, prominent: Bool) -> some View {
        let button = Button {
            perform(action)
        } label: {
            Label(action.title(plan: store.brokerInstallPlan), systemImage: action.systemImage)
        }
        .accessibilityLabel(action.title(plan: store.brokerInstallPlan))
        .disabled(isDisabled(action))

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func perform(_ action: BrokerNextAction) {
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

struct BrokerInstallPlanView: View {
    var store: ControlPlaneStore
    var plan: BrokerInstallPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.title, systemImage: plan.canInstall ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.headline)
            Text(plan.summary)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                pathRow("Install prefix", plan.prefixPath)
                pathRow("App copy", plan.appDestinationPath)
                if shouldShowLegacyAppCleanup {
                    pathRow("Old app cleanup", plan.legacyAppDestinationPath)
                }
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

    private var shouldShowLegacyAppCleanup: Bool {
        plan.legacyAppDestinationPath != plan.appDestinationPath
            && LocalFileOpener.fileExists(atPath: plan.legacyAppDestinationPath)
    }
}

struct BrokerUninstallPlanView: View {
    var plan: BrokerUninstallPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.title, systemImage: plan.canUninstall ? "trash" : "checkmark.circle")
                .font(.headline)
            Text(plan.summary)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                pathRow("Install prefix", plan.prefixPath)
                pathRow("App copy", plan.appDestinationPath)
                if shouldShowLegacyAppCleanup {
                    pathRow("Old app cleanup", plan.legacyAppDestinationPath)
                }
                pathRow("Helpers", plan.binDirectoryPath)
                pathRow("Shims", plan.shimDirectoryPath)
                pathRow("LaunchAgent", plan.launchAgentPath)
                pathRow("Runtime", plan.runDirectoryPath)
                pathRow("Socket directory", plan.socketDirectoryPath)
                pathRow("State", plan.stateDirectoryPath)
            }
            if !plan.managedShellConfigPaths.isEmpty {
                Text("Managed PATH blocks will be removed from known shell startup files when present.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var shouldShowLegacyAppCleanup: Bool {
        plan.legacyAppDestinationPath != plan.appDestinationPath
            && LocalFileOpener.fileExists(atPath: plan.legacyAppDestinationPath)
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

struct ControlPlanePageFrame<Content: View>: View {
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
