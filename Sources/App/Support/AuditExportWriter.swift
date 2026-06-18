import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum AuditExportWriter {
    static func export(store: ManagementStore) {
        guard store.canExportAudit else {
            store.showDaemonRepairGuidance()
            return
        }

        guard let url = chooseDestination() else { return }
        Task {
            guard let audit = await store.loadRedactedAuditForExport() else { return }
            do {
                try audit.write(to: url, atomically: true, encoding: .utf8)
                store.recordAuditExport(to: url)
            } catch {
                store.recordAuditExportFailure(error)
            }
        }
    }

    private static func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Redacted Audit"
        panel.prompt = "Export"
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func defaultFilename(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return "agentic-fortress-audit-\(formatter.string(from: now)).json"
    }
}
