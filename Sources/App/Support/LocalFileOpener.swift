import AppKit
import Foundation

@MainActor
enum LocalFileOpener {
    static func reveal(path: String, label: String, store: ControlPlaneStore) {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fileExists(atPath: normalizedPath) else {
            store.recordLocalOpenFailure(label: label, path: normalizedPath)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: normalizedPath)])
    }

    static func openDirectory(path: String, label: String, store: ControlPlaneStore) {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fileExists(atPath: normalizedPath) else {
            store.recordLocalOpenFailure(label: label, path: normalizedPath)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: normalizedPath, isDirectory: true))
    }

    static func fileExists(atPath path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }
}
