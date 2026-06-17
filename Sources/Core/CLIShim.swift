import Foundation

public enum CLIShimPolicy {
    private static let exactPassThroughFlags: Set<String> = ["--help", "-h", "--version"]
    private static let passThroughSubcommands: Set<String> = ["help", "version"]

    public static func isGlobalPassThrough(arguments: [String]) -> Bool {
        guard !arguments.isEmpty else {
            return false
        }
        if let first = arguments.first, passThroughSubcommands.contains(first) {
            return true
        }
        return arguments.contains { exactPassThroughFlags.contains($0) }
    }
}
