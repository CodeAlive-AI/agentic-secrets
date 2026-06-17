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

                Button("Refresh") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Restart Daemon") {
                    Task { await store.repairDaemon() }
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Button("Install Local Daemon") {
                    Task { await store.installOrRepairDaemon() }
                }
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
        if store.daemonStatus.state == .unavailable || store.daemonStatus.state == .repairing || store.daemonStatus.state == .installing {
            Button(store.daemonInstallPlan?.primaryActionTitle ?? "Install Daemon") {
                Task { await store.installOrRepairDaemon() }
            }
            .disabled(store.daemonStatus.state == .installing || store.daemonStatus.state == .repairing)
            Button("Restart Daemon") {
                Task { await store.repairDaemon() }
            }
            .disabled(store.daemonStatus.state == .installing || store.daemonStatus.state == .repairing)
        }
        Button("Lock Grants") {
            Task { await store.clearUnlockGrants() }
        }
        Button("Refresh") {
            Task { await store.refresh() }
        }
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
