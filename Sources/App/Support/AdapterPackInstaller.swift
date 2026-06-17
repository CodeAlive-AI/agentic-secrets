import AgenticFortressCore
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum AdapterPackInstaller {
    static func presentOpenPanel(store: ManagementStore) {
        let panel = NSOpenPanel()
        panel.title = "Install Adapter Pack"
        panel.prompt = "Install"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(AdapterPackPayload.self, from: Data(contentsOf: url))
            Task { await store.installAdapter(payload: payload) }
        } catch {
            store.errorMessage = "Could not read adapter pack JSON: \(error)"
        }
    }
}
