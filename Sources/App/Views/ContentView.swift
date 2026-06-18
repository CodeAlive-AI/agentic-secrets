import AgenticFortressCore
import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        rootContent
            .sheet(isPresented: $store.showingRegisterCLI) {
                RegisterCLIView(store: store)
            }
            .sheet(isPresented: $store.showingProxyProfileEditor) {
                ProxyProfileEditor(store: store)
            }
            .sheet(isPresented: $store.showingMCPProfileEditor) {
                MCPProfileEditor(store: store)
            }
            .sheet(isPresented: $store.showingBWSBindingEditor) {
                BWSBindingEditor(store: store)
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
                    help: "Refresh local Agentic Fortress state",
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
    @Bindable var store: ManagementStore

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
        case .bws:
            ContextToolbarAction(
                title: "Create BWS Binding",
                systemImage: "plus",
                help: "Create a Bitwarden Secrets Manager binding",
                isEnabled: store.canManageCoreState
            ) {
                store.presentBWSBindingEditor()
            }
        case .proxy:
            ContextToolbarAction(
                title: "Add Proxy Profile",
                systemImage: "plus",
                help: "Add a bounded proxy profile",
                isEnabled: store.canManageCoreState
            ) {
                store.presentProxyProfileEditor()
            }
        case .mcp:
            ContextToolbarAction(
                title: "Add MCP Profile",
                systemImage: "plus",
                help: "Add a pinned MCP upstream profile",
                isEnabled: store.canManageCoreState
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
        case .adapters:
            ContextToolbarAction(
                title: "Install Adapter Pack",
                systemImage: "square.and.arrow.down",
                help: "Install a signed adapter pack JSON payload",
                isEnabled: store.canManageCoreState
            ) {
                AdapterPackInstaller.presentOpenPanel(store: store)
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
    @Bindable var store: ManagementStore

    var body: some View {
        List(selection: $store.selectedSection) {
            Section("Manage") {
                ForEach(ManagementSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
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
        .frame(minWidth: 190)
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

private struct ExternalSidebarLink: View {
    var store: ManagementStore
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
    @Bindable var store: ManagementStore

    var body: some View {
        Group {
            switch store.selectedSection {
            case .overview:
                OverviewView(store: store)
            case .cliSecrets:
                CLISecretsView(store: store)
            case .proxy:
                ProxyProfilesView(store: store)
            case .mcp:
                MCPProfilesView(store: store)
            case .bws:
                BWSView(store: store)
            case .adapters:
                AdaptersView(store: store)
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
    @Bindable var store: ManagementStore

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
