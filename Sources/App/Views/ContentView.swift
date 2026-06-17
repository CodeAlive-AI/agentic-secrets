import AgenticFortressCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: ManagementStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            DetailView(store: store)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search CLIs, aliases, targets")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
            ToolbarItem {
                Button {
                    store.presentRegisterCLI()
                } label: {
                    Label("Register CLI", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.showingRegisterCLI) {
            RegisterCLIView(store: store)
        }
        .alert("Agentic Fortress", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
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
        }
        .listStyle(.sidebar)
        .frame(minWidth: 190)
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
            if store.isLoading {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }
}
