import AppKit
import Foundation

enum ExecutablePathChooser {
    @MainActor
    static func chooseExecutable() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose CLI Executable"
        panel.prompt = "Choose"
        panel.message = "Choose the CLI binary that Agentic Fortress should verify before delivering secrets."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

enum ExecutablePathSelection {
    static func inferredCLIName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func statusMessage(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("/") else {
            return "Use an absolute executable path, or choose the binary from disk."
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            return "This path does not exist yet. Registration will fail until the executable is installed."
        }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else {
            return "This file is not executable. Choose the CLI binary, not a config or document file."
        }
        return nil
    }
}
