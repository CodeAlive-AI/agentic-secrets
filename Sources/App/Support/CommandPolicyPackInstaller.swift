import AgenticSecretsBroker
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum CommandPolicyPackInstaller {
    static func presentOpenPanel(store: ControlPlaneStore) {
        guard store.canManageBrokerState else {
            store.showDaemonRepairGuidance()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Install Command Policy Pack"
        panel.prompt = "Install"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(CommandPolicyPackPayload.self, from: Data(contentsOf: url))
            Task { await store.installAdapter(payload: payload) }
        } catch {
            store.errorMessage = "Could not read command policy pack JSON: \(error)"
        }
    }
}
