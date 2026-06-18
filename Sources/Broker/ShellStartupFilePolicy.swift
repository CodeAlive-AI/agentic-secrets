import Foundation

public enum ShellStartupFilePolicy {
    public static func defaultConfigurationFiles(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        shellPath: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> [URL] {
        let shellName = URL(fileURLWithPath: shellPath ?? "zsh").lastPathComponent
        switch shellName {
        case "zsh":
            return [".zshenv", ".zprofile", ".zshrc"].map { homeDirectory.appendingPathComponent($0) }
        case "bash":
            return [".bash_profile", ".bashrc"].map { homeDirectory.appendingPathComponent($0) }
        default:
            return [homeDirectory.appendingPathComponent(".profile")]
        }
    }

    public static func managedConfigurationFiles(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"].map {
            homeDirectory.appendingPathComponent($0)
        }
    }
}
