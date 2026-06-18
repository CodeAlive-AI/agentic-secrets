import AppKit
import Foundation

@MainActor
enum InstalledAppOpener {
    static func open(store: ManagementStore) {
        guard let url = installedAppURL(store: store) else { return }
        NSWorkspace.shared.open(url)
    }

    static func installedAppURL(store: ManagementStore) -> URL? {
        guard let path = store.daemonInstallPlan?.appDestinationPath, store.canOpenInstalledApp else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
