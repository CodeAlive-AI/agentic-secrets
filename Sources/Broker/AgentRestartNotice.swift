import Foundation

public enum AgentRestartNotice {
    public static func afterCLIRegistration(cliName: String, shimInstalled: Bool) -> String {
        if shimInstalled {
            return "CLI registered and shim installed. Make sure the shims folder is on PATH. Restart Codex or any other already-running agent app before using normal \(cliName) commands from that app so it reloads shell startup files and current Agentic Secrets state."
        }
        return "CLI registered. Restart Codex or any other already-running agent app before using \(cliName) from that app so it refreshes current Agentic Secrets state."
    }

    public static func afterShimPathConfiguration(cliName: String) -> String {
        "Shell PATH configured for future sessions. Restart Codex or any other already-running agent app before using \(cliName) from that app so it reloads shell startup files and sees the Agentic Secrets shim."
    }

    public static func afterManualPathChange(cliName: String) -> String {
        "After changing PATH, restart Codex or any other already-running agent app before using \(cliName) from that app."
    }

    public static func requiresManualDismiss(_ successMessage: String) -> Bool {
        successMessage.contains("Restart Codex")
            || successMessage.contains("already-running agent app")
    }
}
