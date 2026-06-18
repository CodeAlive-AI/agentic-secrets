import AppKit
import SwiftUI

enum PasteboardCopy {
    @discardableResult
    static func write(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
}

struct CopyButton: View {
    var title: String = "Copy"
    var copiedTitle: String = "Copied"
    var systemImage: String = "doc.on.doc"
    var value: String
    var help: String

    @State private var copied = false
    @State private var failed = false
    @State private var copyGeneration = 0

    var body: some View {
        Button {
            copyGeneration += 1
            let generation = copyGeneration
            if PasteboardCopy.write(value) {
                copied = true
                failed = false
            } else {
                copied = false
                failed = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    if copyGeneration == generation {
                        copied = false
                        failed = false
                    }
                }
            }
        } label: {
            Label(displayTitle, systemImage: displaySystemImage)
        }
        .disabled(value.isEmpty)
        .help(helpText)
        .accessibilityLabel(displayTitle)
    }

    private var displayTitle: String {
        if copied { return copiedTitle }
        if failed { return "Copy Failed" }
        return title
    }

    private var displaySystemImage: String {
        if copied { return "checkmark" }
        if failed { return "exclamationmark.triangle" }
        return systemImage
    }

    private var helpText: String {
        if value.isEmpty { return "Nothing to copy" }
        if copied { return copiedTitle }
        if failed { return "Could not write to the pasteboard. Try again." }
        return help
    }
}
