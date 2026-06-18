import AppKit
import Foundation

@MainActor
enum ExternalURLOpener {
    static func open(_ url: URL, label: String, store: ControlPlaneStore) {
        guard NSWorkspace.shared.open(url) else {
            store.recordExternalOpenFailure(label: label, url: url)
            return
        }
    }
}
