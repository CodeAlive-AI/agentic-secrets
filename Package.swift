// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgenticFortress",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgenticFortressCore", targets: ["AgenticFortressCore"]),
        .executable(name: "AgenticFortress", targets: ["AgenticFortressApp"]),
        .executable(name: "agentic-fortress", targets: ["AgenticFortressCLI"]),
        .executable(name: "agentic-fortress-shim", targets: ["AgenticFortressShim"]),
        .executable(name: "agentic-fortressd-core", targets: ["AgenticFortressCoreDaemon"]),
        .executable(name: "agentic-fortress-proxyd", targets: ["AgenticFortressProxyd"]),
        .executable(name: "agentic-fortress-bwsd", targets: ["AgenticFortressBwsd"]),
        .executable(name: "agentic-fortress-mcpd", targets: ["AgenticFortressMcpd"]),
        .executable(name: "agentic-fortress-contract-tests", targets: ["AgenticFortressContractTests"])
    ],
    targets: [
        .target(
            name: "AgenticFortressCore",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "AgenticFortressApp",
            dependencies: ["AgenticFortressCore"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "AgenticFortressCLI",
            dependencies: ["AgenticFortressCore"],
            path: "Sources/CLI"
        ),
        .executableTarget(
            name: "AgenticFortressShim",
            dependencies: ["AgenticFortressCore"],
            path: "Sources/Shim"
        ),
        .executableTarget(
            name: "AgenticFortressCoreDaemon",
            dependencies: ["AgenticFortressCore"],
            path: "Sources/CoreDaemon"
        ),
        .executableTarget(
            name: "AgenticFortressProxyd",
            dependencies: ["AgenticFortressCore"],
            path: "Sources/Proxyd"
        ),
        .executableTarget(
            name: "AgenticFortressBwsd",
            dependencies: ["AgenticFortressCore"],
            path: "Sources/Bwsd"
        ),
        .executableTarget(
            name: "AgenticFortressMcpd",
            dependencies: ["AgenticFortressCore"],
            path: "Sources/Mcpd"
        ),
        .executableTarget(
            name: "AgenticFortressContractTests",
            dependencies: ["AgenticFortressCore"],
            path: "Sources/ContractTests"
        )
    ]
)
