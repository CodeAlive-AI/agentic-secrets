// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgenticFortress",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgenticFortressCore", targets: ["AgenticFortressCore"]),
        .executable(name: "agentic-fortress", targets: ["AgenticFortressCLI"]),
        .executable(name: "agentic-fortress-shim", targets: ["AgenticFortressShim"]),
        .executable(name: "agentic-fortressd-core", targets: ["AgenticFortressCoreDaemon"]),
        .executable(name: "agentic-fortress-proxyd", targets: ["AgenticFortressProxyd"]),
        .executable(name: "agentic-fortress-bwsd", targets: ["AgenticFortressBwsd"]),
        .executable(name: "agentic-fortress-mcpd", targets: ["AgenticFortressMcpd"]),
        .executable(name: "agentic-fortress-contract-tests", targets: ["AgenticFortressContractTests"])
    ],
    targets: [
        .target(name: "AgenticFortressCore"),
        .executableTarget(
            name: "AgenticFortressCLI",
            dependencies: ["AgenticFortressCore"]
        ),
        .executableTarget(
            name: "AgenticFortressShim",
            dependencies: ["AgenticFortressCore"]
        ),
        .executableTarget(
            name: "AgenticFortressCoreDaemon",
            dependencies: ["AgenticFortressCore"]
        ),
        .executableTarget(
            name: "AgenticFortressProxyd",
            dependencies: ["AgenticFortressCore"]
        ),
        .executableTarget(
            name: "AgenticFortressBwsd",
            dependencies: ["AgenticFortressCore"]
        ),
        .executableTarget(
            name: "AgenticFortressMcpd",
            dependencies: ["AgenticFortressCore"]
        ),
        .executableTarget(
            name: "AgenticFortressContractTests",
            dependencies: ["AgenticFortressCore"]
        )
    ]
)
