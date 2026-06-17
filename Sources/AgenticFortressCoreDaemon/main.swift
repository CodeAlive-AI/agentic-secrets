import AgenticFortressCore
import Foundation

@main
struct AgenticFortressCoreDaemon {
    static func main() throws {
        let report = ReleaseGateRunner().staticReport()
        print(try AgenticFortressJSON.encodePretty([
            "service": "agentic-fortressd-core",
            "mode": "contract-check",
            "can_release": String(report.canRelease),
            "note": "Production deployment must add signed XPC peer validation and Keychain-backed policy storage."
        ]))
    }
}

