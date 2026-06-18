import AgenticSecretsBroker
import Foundation

@main
struct AgenticSecretsBitwardenProviderDaemon {
    static func main() throws {
        let binding = BitwardenSecretBinding(alias: "cloud.hcloud.dev", projectID: "cloud-dev", secretID: "sec_hcloud", environment: "dev")
        let invocation = try BitwardenProviderPolicy().authorizeRuntimeRead(alias: binding.alias, bindings: [binding], sinkIdentity: "agentic-secrets-shim")
        print(try AgenticSecretsJSON.encodePretty(invocation))
    }
}

