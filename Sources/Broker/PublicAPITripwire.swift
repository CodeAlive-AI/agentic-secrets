import Foundation

public enum PublicAPITripwire {
    static let forbiddenSymbols = ["getSecret", "listSecretsRuntime", "fetchProjectRuntime", "loadAllEnv"]

    public static func scan(source: String) -> [String] {
        forbiddenSymbols.filter { source.contains($0) }
    }
}
