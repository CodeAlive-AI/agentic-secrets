// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgenticSecrets",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgenticSecretsBroker", targets: ["AgenticSecretsBroker"]),
        .executable(name: "AgenticSecrets", targets: ["AgenticSecretsApp"]),
        .executable(name: "agentic-secrets", targets: ["AgenticSecretsCLI"]),
        .executable(name: "agentic-secrets-shim", targets: ["AgenticSecretsCommandShim"]),
        .executable(name: "agentic-secrets-brokerd", targets: ["AgenticSecretsBrokerDaemon"]),
        .executable(name: "agentic-secrets-api-sessiond", targets: ["AgenticSecretsAPISessionDaemon"]),
        .executable(name: "agentic-secrets-bitwarden-providerd", targets: ["AgenticSecretsBitwardenProviderDaemon"]),
        .executable(name: "agentic-secrets-mcpd", targets: ["AgenticSecretsMCPDaemon"]),
        .executable(name: "agentic-secrets-contract-tests", targets: ["AgenticSecretsContractTests"])
    ],
    targets: [
        .target(
            name: "AgenticSecretsBroker",
            path: "Sources/Broker"
        ),
        .executableTarget(
            name: "AgenticSecretsApp",
            dependencies: ["AgenticSecretsBroker"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "AgenticSecretsCLI",
            dependencies: ["AgenticSecretsBroker"],
            path: "Sources/CLI"
        ),
        .executableTarget(
            name: "AgenticSecretsCommandShim",
            dependencies: ["AgenticSecretsBroker"],
            path: "Sources/CommandShim"
        ),
        .executableTarget(
            name: "AgenticSecretsBrokerDaemon",
            dependencies: ["AgenticSecretsBroker"],
            path: "Sources/BrokerDaemon"
        ),
        .executableTarget(
            name: "AgenticSecretsAPISessionDaemon",
            dependencies: ["AgenticSecretsBroker"],
            path: "Sources/APISessionDaemon"
        ),
        .executableTarget(
            name: "AgenticSecretsBitwardenProviderDaemon",
            dependencies: ["AgenticSecretsBroker"],
            path: "Sources/BitwardenProviderDaemon"
        ),
        .executableTarget(
            name: "AgenticSecretsMCPDaemon",
            dependencies: ["AgenticSecretsBroker"],
            path: "Sources/MCPDaemon"
        ),
        .executableTarget(
            name: "AgenticSecretsContractTests",
            dependencies: ["AgenticSecretsBroker"],
            path: "Sources/ContractTests"
        )
    ]
)
