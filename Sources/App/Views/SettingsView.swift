import AgenticFortressCore
import SwiftUI

struct SettingsView: View {
    var store: ManagementStore
    @AppStorage("launchMenuBarStatus") private var launchMenuBarStatus = true
    @State private var commandPolicyDraft = CommandPolicySettingsDraftState()
    @State private var previewCommand = "hcloud server delete prod-db-01"

    var body: some View {
        TabView {
            Form {
                Toggle("Show menu bar status", isOn: $launchMenuBarStatus)
                    .help("Show AgenticFortress health and grant status in the macOS menu bar")
                Section("CLI Unlock Grants") {
                    LabeledContent("Default TTL", value: "\(Int(CLIUnlockGrantPolicy.defaultTTL))s")
                    LabeledContent("Maximum TTL", value: "\(Int(CLIUnlockGrantPolicy.maxTTL))s")
                    Text("CLI runs may override the TTL per invocation with --unlock-ttl-seconds. This app does not store a separate local TTL preference.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            CommandPolicySettingsPage(
                terms: $commandPolicyDraft.terms,
                previewCommand: $previewCommand,
                hasChanges: commandPolicyDraft.hasChanges,
                canSave: store.canManageCoreState,
                isLoading: store.isLoading,
                saveHelp: saveHelp,
                revert: { syncCommandPolicyFromSnapshot(force: true) },
                save: savePolicy
            )
            .tabItem { Label("Command Policy", systemImage: "shield.lefthalf.filled") }

            Form {
                LabeledContent("State directory", value: store.snapshot?.stateDirectory ?? "Not loaded")
                LabeledContent("Config path", value: store.snapshot?.configPath ?? "Not loaded")
            }
            .padding()
            .tabItem { Label("State", systemImage: "externaldrive") }
        }
        .frame(width: 920, height: 660)
        .onAppear {
            syncCommandPolicyFromSnapshot(force: false)
        }
        .task {
            await store.refresh()
            syncCommandPolicyFromSnapshot(force: false)
        }
        .onChange(of: store.snapshot?.generatedAt) { _, _ in
            syncCommandPolicyFromSnapshot(force: false)
        }
    }

    private var destructiveTerms: [String] {
        CommandPolicyTermDraft.destructiveTerms(from: commandPolicyDraft.terms)
    }

    private var forbiddenTerms: [String] {
        CommandPolicyTermDraft.forbiddenTerms(from: commandPolicyDraft.terms)
    }

    private var saveHelp: String {
        if !store.canManageCoreState {
            return "Start or repair the local daemon before saving policy"
        }
        if !commandPolicyDraft.hasChanges {
            return "Command policy is already saved"
        }
        return "Save command policy to the local core config"
    }

    private func syncCommandPolicyFromSnapshot(force: Bool) {
        commandPolicyDraft.sync(summary: store.snapshot?.commandPolicy, force: force)
    }

    private func savePolicy() {
        Task {
            let didSave = await store.updateCommandPolicy(destructiveTerms: destructiveTerms, forbiddenTerms: forbiddenTerms)
            if didSave {
                syncCommandPolicyFromSnapshot(force: true)
            }
        }
    }
}
