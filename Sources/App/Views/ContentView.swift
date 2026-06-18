import AgenticSecretsBroker
import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: ControlPlaneStore

    var body: some View {
        rootContent
            .sheet(isPresented: $store.showingRegisterCLI) {
                RegisterCLIView(store: store)
            }
            .sheet(isPresented: $store.showingAPISessionProfileEditor) {
                APISessionProfileEditor(store: store)
            }
            .sheet(isPresented: $store.showingMCPProfileEditor) {
                MCPProfileEditor(store: store)
            }
            .sheet(isPresented: $store.showingBitwardenBindingEditor) {
                BitwardenBindingEditor(store: store)
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if store.usesToolbarSearch {
            splitView
                .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search CLIs, aliases, targets")
        } else {
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            DetailView(store: store)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                ToolbarIconButton(
                    title: "Refresh",
                    systemImage: "arrow.clockwise",
                    help: "Refresh local Agentic Secrets state",
                    isEnabled: !store.isLoading
                ) {
                    Task { await store.refresh() }
                }
                ContextToolbarActionSlot(store: store)
            }
        }
    }
}

private struct ToolbarIconButton: View {
    var title: String
    var systemImage: String
    var help: String
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(title)
        .disabled(!isEnabled)
    }
}

private struct ContextToolbarActionSlot: View {
    @Bindable var store: ControlPlaneStore

    var body: some View {
        if let action = action {
            ToolbarIconButton(
                title: action.title,
                systemImage: action.systemImage,
                help: action.help,
                isEnabled: action.isEnabled
            ) {
                action.perform()
            }
        } else {
            Label("No Context Action", systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 24)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var action: ContextToolbarAction? {
        switch store.selectedSection {
        case .overview, .cliSecrets:
            ContextToolbarAction(
                title: "Register CLI",
                systemImage: "plus",
                help: "Register a CLI and bind write-only secrets",
                isEnabled: store.canRegisterCLI
            ) {
                store.presentRegisterCLI()
            }
        case .bitwardenProviderBindings:
            ContextToolbarAction(
                title: "Create Bitwarden Provider Binding",
                systemImage: "plus",
                help: "Create a Bitwarden Secrets Manager binding",
                isEnabled: store.canManageBrokerState
            ) {
                store.presentBitwardenBindingEditor()
            }
        case .apiSessions:
            ContextToolbarAction(
                title: "Add API Session Profile",
                systemImage: "plus",
                help: "Add a bounded API session profile",
                isEnabled: store.canManageBrokerState
            ) {
                store.presentAPISessionProfileEditor()
            }
        case .mcp:
            ContextToolbarAction(
                title: "Add MCP Proxy",
                systemImage: "plus",
                help: "Add a pinned MCP proxy upstream",
                isEnabled: store.canManageBrokerState
            ) {
                store.presentMCPProfileEditor()
            }
        case .audit:
            ContextToolbarAction(
                title: "Export Redacted Audit",
                systemImage: "square.and.arrow.up",
                help: "Export redacted audit JSON",
                isEnabled: store.canExportAudit
            ) {
                AuditExportWriter.export(store: store)
            }
        case .policyPacks:
            ContextToolbarAction(
                title: "Install Command Policy Pack",
                systemImage: "square.and.arrow.down",
                help: "Install a signed command policy pack JSON payload",
                isEnabled: store.canManageBrokerState
            ) {
                CommandPolicyPackInstaller.presentOpenPanel(store: store)
            }
        case .diagnostics:
            nil
        }
    }
}

private struct ContextToolbarAction {
    var title: String
    var systemImage: String
    var help: String
    var isEnabled: Bool
    var perform: () -> Void
}

struct SidebarView: View {
    @Bindable var store: ControlPlaneStore

    var body: some View {
        List(selection: $store.selectedSection) {
            Section("Manage") {
                ForEach(ControlPlaneSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
                Button {
                    AboutWindowController.shared.show()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
                .buttonStyle(.plain)
                .help("About Agentic Secrets")
                .accessibilityLabel("About Agentic Secrets")
            }
            Section {
                SidebarDivider()
                ExternalSidebarLink(
                    store: store,
                    title: "SSH",
                    subtitle: "secretive.dev",
                    systemImage: "key",
                    destination: URL(string: "https://secretive.dev/")!
                )
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarReleaseFooter(store: store)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
    }
}

private struct SidebarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.leading, 27)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
    }
}

private struct SidebarReleaseFooter: View {
    var store: ControlPlaneStore
    private let releasesURL = URL(string: "https://github.com/CodeAlive-AI/agentic-secrets/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.bottom, 8)
            Text("Version \(AppVersionInfo.displayVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let update = store.availableUpdate {
                SidebarUpdateButton(store: store, update: update)
            } else {
                HStack(spacing: 8) {
                    SidebarTextLink(
                        store: store,
                        title: "releases",
                        destination: releasesURL,
                        accessibilityLabel: "Open Agentic Secrets releases"
                    )
                    Spacer(minLength: 0)
                    if store.isCheckingForUpdates {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking for updates")
                    } else {
                        Button {
                            Task { await store.checkForUpdates(manual: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Check for updates")
                        .accessibilityLabel("Check for updates")
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct SidebarUpdateButton: View {
    var store: ControlPlaneStore
    var update: AppUpdateRelease

    var body: some View {
        Button {
            ExternalURLOpener.open(update.htmlURL, label: "Agentic Secrets update", store: store)
        } label: {
            Label {
                Text(update.critical ? "Critical Update" : "Update \(update.versionLabel)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.green)
        .help("Open \(update.displayName) release notes")
        .accessibilityLabel("Open update \(update.versionLabel)")
    }
}

private struct SidebarTextLink: View {
    var store: ControlPlaneStore
    var title: String
    var destination: URL
    var accessibilityLabel: String
    @State private var isHovering = false

    var body: some View {
        Button {
            ExternalURLOpener.open(destination, label: title, store: store)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.link)
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundStyle(.link)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .help(destination.absoluteString)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }
}

private struct ExternalSidebarLink: View {
    var store: ControlPlaneStore
    var title: String
    var subtitle: String
    var systemImage: String
    var destination: URL
    @State private var isHovering = false

    var body: some View {
        Button {
            ExternalURLOpener.open(destination, label: title, store: store)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .foregroundStyle(.link)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.link)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Secretive for SSH key management")
        .accessibilityLabel("\(title), external link to \(subtitle)")
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }
}

struct DetailView: View {
    @Bindable var store: ControlPlaneStore

    var body: some View {
        Group {
            switch store.selectedSection {
            case .overview:
                OverviewView(store: store)
            case .cliSecrets:
                CLISecretsView(store: store)
            case .apiSessions:
                APISessionProfilesView(store: store)
            case .mcp:
                MCPProfilesView(store: store)
            case .bitwardenProviderBindings:
                BitwardenProviderBindingsView(store: store)
            case .policyPacks:
                CommandPolicyPacksView(store: store)
            case .audit:
                AuditView(store: store)
            case .diagnostics:
                DiagnosticsView(store: store)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if store.isLoading {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if store.successMessage != nil || store.errorMessage != nil {
                    FeedbackBanner(store: store)
                }
            }
            .padding()
        }
    }
}

private struct FeedbackBanner: View {
    @Bindable var store: ControlPlaneStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(store.errorMessage == nil ? .green : .orange)
            Text(store.errorMessage ?? store.successMessage ?? "")
                .lineLimit(2)
            Button {
                store.clearFeedback()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss status message")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .task(id: store.successMessage) {
            guard let message = store.successMessage, store.errorMessage == nil else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run {
                store.clearSuccessIfCurrent(message)
            }
        }
    }
}
