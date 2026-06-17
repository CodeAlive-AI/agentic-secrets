import AppKit
import SwiftUI

@main
struct AgenticFortressApp: App {
    @State private var store = ManagementStore(client: DefaultAgenticFortressClient.make())

    init() {
        if CommandLine.arguments.contains("--ui-smoke") {
            UISmokeRunner.runAndExit()
        }
    }

    var body: some Scene {
        WindowGroup("Agentic Fortress", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 620)
                .task {
                    await store.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await store.checkDaemon() }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Register CLI") {
                    store.presentRegisterCLI()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!store.canRegisterCLI)

                Button("Refresh") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isLoading)

                Button(store.bestDaemonAction?.title(plan: store.daemonInstallPlan) ?? "Check Daemon") {
                    if let action = store.bestDaemonAction {
                        performDaemonAction(action, store: store)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(store.bestDaemonAction == nil || store.isLoading)

                Button("Lock Grants") {
                    Task { await store.clearUnlockGrants() }
                }
                .disabled(!store.canClearUnlockGrants)

                Button("Export Redacted Audit") {
                    Task { await store.exportAudit() }
                }
                .disabled(!store.canExportAudit)
            }

            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Settings...")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarActions(store: store)
        } label: {
            Label("Agentic Fortress", systemImage: store.menuBarSymbol)
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

private struct MenuBarActions: View {
    var store: ManagementStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Agentic Fortress") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Divider()
        Text(store.menuBarSummary)
        if let action = store.bestDaemonAction {
            Button(action.title(plan: store.daemonInstallPlan)) {
                performDaemonAction(action, store: store)
            }
            .disabled(store.isLoading)
        }
        Button("Lock Grants") {
            Task { await store.clearUnlockGrants() }
        }
        .disabled(!store.canClearUnlockGrants)
        Button("Refresh") {
            Task { await store.refresh() }
        }
        .disabled(store.isLoading)
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private func performDaemonAction(_ action: DaemonNextAction, store: ManagementStore) {
    switch action {
    case .check:
        Task { await store.checkDaemon() }
    case .installOrRepair:
        Task { await store.installOrRepairDaemon() }
    case .restart:
        Task { await store.repairDaemon() }
    case .openInstalledApp:
        guard let path = store.daemonInstallPlan?.appDestinationPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
