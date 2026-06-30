import AgenticSecretsBroker
import SwiftUI

struct SettingsView: View {
    var store: ControlPlaneStore
    @AppStorage("launchMenuBarStatus") private var launchMenuBarStatus = true
    @State private var commandPolicyDraft = CommandPolicySettingsDraftState()
    @State private var previewCommand = "supabase projects delete prod-ref"

    var body: some View {
        TabView {
            Form {
                Toggle("Show menu bar status", isOn: $launchMenuBarStatus)
                    .help("Show Agentic Secrets health and grant status in the macOS menu bar")
                Section("CLI Authorization Grants") {
                    LabeledContent("Default mode", value: RememberedApprovalPolicy.defaultMode.rawValue)
                    LabeledContent("24h mode", value: "\(Int(RememberedApprovalPolicy.remember24HTTL / 3600))h")
                    LabeledContent("Default TTL", value: "\(Int(DeliveryGrantPolicy.defaultTTL))s")
                    LabeledContent("Maximum TTL", value: "\(Int(DeliveryGrantPolicy.maxTTL))s")
                    Text("CLI runs may choose --authorization-mode once, short, remember-24h, or always. Short mode may override TTL per invocation with --delivery-grant-ttl-seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            CommandPolicySettingsPage(
                terms: $commandPolicyDraft.terms,
                authorizationMode: $commandPolicyDraft.cliAuthorizationMode,
                previewCommand: $previewCommand,
                hasChanges: commandPolicyDraft.hasChanges,
                canSave: store.canManageBrokerState,
                isLoading: store.isLoading,
                saveHelp: saveHelp,
                revert: { syncCommandPolicyFromSnapshot(force: true) },
                save: savePolicy
            )
            .tabItem { Label("CLI Delivery", systemImage: "shield.lefthalf.filled") }

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
        if !store.canManageBrokerState {
            return "Start or repair the local daemon before saving policy"
        }
        if !commandPolicyDraft.hasChanges {
            return "CLI delivery settings are already saved"
        }
        return "Save CLI delivery settings to the local broker config"
    }

    private func syncCommandPolicyFromSnapshot(force: Bool) {
        commandPolicyDraft.sync(
            summary: store.snapshot?.commandPolicy,
            deliveryDefaults: store.snapshot?.deliveryDefaults,
            force: force
        )
    }

    private func savePolicy() {
        Task {
            let didSave = await store.updateCommandPolicy(
                destructiveTerms: destructiveTerms,
                forbiddenTerms: forbiddenTerms,
                cliAuthorizationMode: commandPolicyDraft.cliAuthorizationMode
            )
            if didSave {
                syncCommandPolicyFromSnapshot(force: true)
            }
        }
    }
}
