import Foundation

enum CLIShimInstaller {
    static func install(name: String) throws -> String {
        try runCLI(arguments: ["cli", "shim", "install", name])
    }

    static func uninstall(name: String) throws -> String {
        try runCLI(arguments: ["cli", "shim", "uninstall", name])
    }

    private static func runCLI(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try cliPath())
        process.arguments = arguments
        process.environment = subprocessEnvironment()

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        process.waitUntilExit()

        let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CLIShimInstallerError.failed(errorText.isEmpty ? outputText : errorText)
        }
        return outputText
    }

    private static func cliPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_SECRETS_CLI_BINARY"], !override.isEmpty {
            return override
        }
        if let prefix = IPCControlPlaneClient.installPrefixFromBundle() {
            let installed = prefix.appendingPathComponent("bin/agentic-secrets")
            if FileManager.default.isExecutableFile(atPath: installed.path) {
                return installed.path
            }
        }
        let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("agentic-secrets")
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling.path
        }
        throw CLIShimInstallerError.missingCLI
    }

    static func subprocessEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        installPrefix: URL? = IPCControlPlaneClient.installPrefixFromBundle()
    ) -> [String: String] {
        var environment = base
        if let installPrefix {
            environment["AGENTIC_SECRETS_INSTALL_PREFIX"] = installPrefix.path
            environment["AGENTIC_SECRETS_SHIM_DIR"] = installPrefix.appendingPathComponent("shims", isDirectory: true).path
            environment["AGENTIC_SECRETS_SHIM_BINARY"] = installPrefix.appendingPathComponent("bin/agentic-secrets-shim").path
        }
        return environment
    }
}

enum CLIShimInstallerError: Error, CustomStringConvertible {
    case missingCLI
    case failed(String)

    var description: String {
        switch self {
        case .missingCLI:
            "Could not find the local agentic-secrets CLI helper needed to install the shim."
        case .failed(let message):
            message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
