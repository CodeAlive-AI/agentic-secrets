import AgenticSecretsBroker
import Foundation

@main
struct AgenticSecretsBitwardenProviderDaemon {
    static func main() throws {
        let binding = BitwardenSecretBinding(alias: "supabase.db.dev", projectID: "supabase-dev", secretID: "sec_supabase_db_password", environment: "dev")
        let invocation = try BitwardenProviderPolicy().authorizeRuntimeRead(alias: binding.alias, bindings: [binding], sinkIdentity: "agentic-secrets-shim")
        print(try AgenticSecretsJSON.encodePretty(invocation))
    }
}

