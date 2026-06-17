import Foundation

public struct Redactor {
    public init() {}

    public func redact(_ input: String) -> String {
        var output = input
        output = output.replacing(#/sk-[A-Za-z0-9_-]{12,}/#, with: "[REDACTED]")
        output = output.replacing(#/xox[baprs]-[A-Za-z0-9-]{10,}/#, with: "[REDACTED]")
        output = output.replacing(#/gh[pousr]_[A-Za-z0-9_]{20,}/#, with: "[REDACTED]")
        output = output.replacing(#/AKIA[0-9A-Z]{16}/#, with: "[REDACTED]")
        output = output.replacing(#/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/#, with: "[REDACTED]")
        output = output.replacing(#/[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY)[A-Za-z0-9_]*=[^\s]+/#, with: "[REDACTED]")
        output = redactURLQueries(output)
        output = redactAuthorizationHeaders(output)
        return output
    }

    public func redactArguments(_ arguments: [String]) -> [String] {
        arguments.map { redact($0) }
    }

    private func redactURLQueries(_ input: String) -> String {
        input.replacing(#/([?&](?:token|key|secret|password|access_token|api_key)=)[^&\s]+/#) { match in
            "\(match.1)[REDACTED]"
        }
    }

    private func redactAuthorizationHeaders(_ input: String) -> String {
        input.replacing(#/((?:Authorization|authorization):\s*Bearer\s+)[A-Za-z0-9._~+/=-]+/#) { match in
            "\(match.1)[REDACTED]"
        }
    }
}
