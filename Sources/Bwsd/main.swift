import AgenticFortressCore
import Foundation

@main
struct AgenticFortressBwsd {
    static func main() throws {
        let binding = BWSSecretBinding(alias: "cloud.hcloud.dev", projectID: "cloud-dev", secretID: "sec_hcloud", environment: "dev")
        let invocation = try BWSProviderPolicy().authorizeRuntimeRead(alias: binding.alias, bindings: [binding], sinkIdentity: "agentic-fortress-shim")
        print(try AgenticFortressJSON.encodePretty(invocation))
    }
}

