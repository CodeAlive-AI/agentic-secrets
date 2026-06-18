import AppKit
import SwiftUI

private enum AppWindowSizing {
    static let defaultWidth: CGFloat = 1180
    static let defaultHeight: CGFloat = 760
    static let minimumWidth: CGFloat = 1180
    static let minimumHeight: CGFloat = 620
}

enum AppVersionInfo {
    static let fallbackVersion = "0.1.0"

    static var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version?.isEmpty == false ? version! : fallbackVersion
    }
}

@main
struct AgenticFortressApp: App {
    @NSApplicationDelegateAdaptor(AgenticFortressAppDelegate.self) private var appDelegate
    @AppStorage("launchMenuBarStatus") private var launchMenuBarStatus = true
    @State private var store = AgenticFortressAppModel.shared.store

    init() {
        if CommandLine.arguments.contains("--ui-smoke") {
            UISmokeRunner.runAndExit()
        }
    }

    var body: some Scene {
        WindowGroup("Agentic Fortress", id: "main-window") {
            MainWindowContent(store: store)
        }
        .defaultSize(width: AppWindowSizing.defaultWidth, height: AppWindowSizing.defaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Agentic Fortress") {
                    AboutWindowController.shared.show()
                }
            }
            CommandGroup(after: .newItem) {
                Button("Register CLI") {
                    store.presentRegisterCLI()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!store.canRegisterCLI)

                Button("Add Proxy Profile") {
                    store.presentProxyProfileEditor()
                }
                .disabled(!store.canManageCoreState)

                Button("Add MCP Profile") {
                    store.presentMCPProfileEditor()
                }
                .disabled(!store.canManageCoreState)

                Button("Create BWS Binding") {
                    store.presentBWSBindingEditor()
                }
                .disabled(!store.canManageCoreState)

                Button("Install Adapter Pack") {
                    AdapterPackInstaller.presentOpenPanel(store: store)
                }
                .disabled(!store.canManageCoreState)

                Divider()

                Button("Refresh") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isLoading)

                Button("Open Diagnostics") {
                    openDiagnostics(store: store)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(store.bestDaemonAction?.title(plan: store.daemonInstallPlan) ?? "Check Daemon") {
                    if let action = store.bestDaemonAction {
                        performDaemonAction(action, store: store)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(store.bestDaemonAction == nil || store.isLoading)

                Button("Open Installed Copy") {
                    openInstalledAppCopy(store: store)
                }
                .disabled(!store.canOpenInstalledApp)

                Button("Lock Grants") {
                    Task { await store.clearUnlockGrants() }
                }
                .disabled(!store.canClearUnlockGrants)

                Button("Export Redacted Audit") {
                    AuditExportWriter.export(store: store)
                }
                .disabled(!store.canExportAudit)
            }
        }

        MenuBarExtra(isInserted: $launchMenuBarStatus) {
            MenuBarActions(store: store)
        } label: {
            Label("Agentic Fortress", systemImage: store.menuBarSymbol)
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

@MainActor
private final class AgenticFortressAppModel {
    static let shared = AgenticFortressAppModel()

    let store = ManagementStore(client: DefaultAgenticFortressClient.make())

    private init() {}
}

private final class AgenticFortressAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ensureMainWindowSoon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        if !MainWindowController.shared.showExistingWindow() {
            ensureMainWindowSoon(delay: 0)
        }
        return true
    }

    private func ensureMainWindowSoon(delay: TimeInterval = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainWindowController.shared.showIfNeeded(store: AgenticFortressAppModel.shared.store)
        }
    }
}

@MainActor
private final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    private init() {}

    func showIfNeeded(store: ManagementStore) {
        if showExistingWindow() {
            return
        }

        let content = MainWindowContent(store: store)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AppWindowSizing.defaultWidth,
                height: AppWindowSizing.defaultHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Agentic Fortress"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: AppWindowSizing.minimumWidth, height: AppWindowSizing.minimumHeight)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @discardableResult
    func showExistingWindow() -> Bool {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        if let existing = NSApp.windows.first(where: { $0.title == "Agentic Fortress" && $0.isVisible }) {
            window = existing
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        return false
    }
}

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: AboutView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "About Agentic Fortress"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct AboutView: View {
    private let repositoryURL = URL(string: "https://github.com/CodeAlive-AI/agentic-secrets")!
    private let codeAliveURL = URL(string: "https://codealive.ai/")!

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Agentic Fortress")
                    .font(.title2.bold())
                Text("Version \(AppVersionInfo.displayVersion)")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                AboutLinkButton(
                    title: "CodeAlive-AI/agentic-secrets",
                    destination: repositoryURL,
                    accessibilityLabel: "Open GitHub repository"
                )
                Text("Lower-leakage secret delivery for developer machines.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("Sponsored by")
                        .foregroundStyle(.secondary)
                    AboutLinkButton(
                        title: "CodeAlive.ai",
                        destination: codeAliveURL,
                        accessibilityLabel: "Open CodeAlive dot AI"
                    )
                }
                Text("(context engine for large codebases)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(28)
        .frame(width: 420, height: 300)
    }
}

private struct AboutLinkButton: View {
    var title: String
    var destination: URL
    var accessibilityLabel: String
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(destination)
        } label: {
            Text(title)
                .foregroundStyle(.link)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct MainWindowContent: View {
    @Bindable var store: ManagementStore

    var body: some View {
        ContentView(store: store)
            .frame(minWidth: AppWindowSizing.minimumWidth, minHeight: AppWindowSizing.minimumHeight)
            .task {
                await store.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await store.refreshAfterActivation() }
            }
    }
}

private struct MenuBarActions: View {
    var store: ManagementStore

    var body: some View {
        Button("Open Agentic Fortress") {
            MainWindowController.shared.showIfNeeded(store: store)
        }
        SettingsLink {
            Text("Settings")
        }
        Divider()
        Text(store.menuBarSummary)
        if let action = store.bestDaemonAction {
            Button(action.title(plan: store.daemonInstallPlan)) {
                performDaemonAction(action, store: store)
            }
            .disabled(store.isLoading)
        }
        Button("Open Diagnostics") {
            openDiagnostics(store: store)
        }
        Button("Open Installed Copy") {
            openInstalledAppCopy(store: store)
        }
        .disabled(!store.canOpenInstalledApp)
        Menu("Recent Activity") {
            if store.menuBarRecentActivityTitles.isEmpty {
                Text("No Recent Activity")
            } else {
                ForEach(Array(store.menuBarRecentActivityTitles.enumerated()), id: \.offset) { _, title in
                    Button(title) {
                        openAudit(store: store)
                    }
                }
            }
            Divider()
            Button("Open Audit") {
                openAudit(store: store)
            }
        }
        Button("Lock Grants") {
            Task { await store.clearUnlockGrants() }
        }
        .disabled(!store.canClearUnlockGrants)
        Button("Export Redacted Audit") {
            AuditExportWriter.export(store: store)
        }
        .disabled(!store.canExportAudit)
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
private func openAudit(store: ManagementStore) {
    store.selectedSection = .audit
    MainWindowController.shared.showIfNeeded(store: store)
}

@MainActor
private func openDiagnostics(store: ManagementStore) {
    store.presentDiagnostics()
    MainWindowController.shared.showIfNeeded(store: store)
}

@MainActor
private func openInstalledAppCopy(store: ManagementStore) {
    InstalledAppOpener.open(store: store)
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
        openInstalledAppCopy(store: store)
    }
}
