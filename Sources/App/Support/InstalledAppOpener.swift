import AppKit
import Foundation

@MainActor
enum InstalledAppOpener {
    static func open(store: ControlPlaneStore) {
        guard let url = installedAppURL(store: store) else { return }
        NSWorkspace.shared.open(url)
    }

    static func installedAppURL(store: ControlPlaneStore) -> URL? {
        guard let path = store.brokerInstallPlan?.appDestinationPath, store.canOpenInstalledApp else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
