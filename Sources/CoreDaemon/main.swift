import AgenticFortressCore
import Foundation

@main
struct AgenticFortressCoreDaemon {
    static func main() throws {
        let report = ReleaseGateRunner().staticReport()
        print(try AgenticFortressJSON.encodePretty([
            "service": "agentic-fortressd-core",
            "mode": "local-self-build",
            "can_run_local": String(report.canRunLocal),
            "can_distribute_binary": String(report.canDistributeBinary),
            "note": "Default production track is self-build with local ad-hoc signing; Developer ID distribution is optional future maintainer work."
        ]))
    }
}
