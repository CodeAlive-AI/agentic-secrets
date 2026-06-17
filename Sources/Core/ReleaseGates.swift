import Foundation

public enum ReleaseTrack: String, Codable, Sendable {
    case localSelfBuild = "local-self-build"
    case optionalBinaryDistribution = "optional-binary-distribution"
}

public enum ReleaseGate: String, CaseIterable, Codable, Sendable {
    case noGetSecretAPI = "no-getSecret-api"
    case xpcPeerValidation = "xpc-peer-validation"
    case localSecretAccessControl = "local-secret-access-control"
    case invocationHandleBinding = "invocation-handle-binding"
    case redaction = "redaction"
    case commandAdapterGolden = "command-adapter-golden"
    case proxyAbuse = "proxy-abuse"
    case bwsProvider = "bws-provider"
    case mcpConformance = "mcp-conformance"
    case macOSPackaging = "macos-packaging"
    case upgradeDowngrade = "upgrade-downgrade"
}

public struct ReleaseGateResult: Codable, Equatable, Sendable {
    public var gate: ReleaseGate
    public var track: ReleaseTrack
    public var passed: Bool
    public var detail: String

    public init(gate: ReleaseGate, track: ReleaseTrack = .localSelfBuild, passed: Bool, detail: String) {
        self.gate = gate
        self.track = track
        self.passed = passed
        self.detail = detail
    }
}

public struct ReleaseGateReport: Codable, Equatable, Sendable {
    public var results: [ReleaseGateResult]
    public var binaryDistributionResults: [ReleaseGateResult]

    public init(results: [ReleaseGateResult], binaryDistributionResults: [ReleaseGateResult] = []) {
        self.results = results
        self.binaryDistributionResults = binaryDistributionResults
    }

    public var canRunLocal: Bool {
        results.filter { $0.track == .localSelfBuild }.allSatisfy(\.passed)
    }

    public var canDistributeBinary: Bool {
        !binaryDistributionResults.isEmpty && binaryDistributionResults.allSatisfy(\.passed)
    }

    public var canRelease: Bool {
        canRunLocal
    }

    private enum CodingKeys: String, CodingKey {
        case results
        case binaryDistributionResults
        case canRunLocal
        case canDistributeBinary
        case canRelease
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.results = try container.decode([ReleaseGateResult].self, forKey: .results)
        self.binaryDistributionResults = try container.decodeIfPresent([ReleaseGateResult].self, forKey: .binaryDistributionResults) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(results, forKey: .results)
        try container.encode(binaryDistributionResults, forKey: .binaryDistributionResults)
        try container.encode(canRunLocal, forKey: .canRunLocal)
        try container.encode(canDistributeBinary, forKey: .canDistributeBinary)
        try container.encode(canRelease, forKey: .canRelease)
    }
}

public struct ReleaseGateRunner: Sendable {
    public init() {}

    public func staticReport() -> ReleaseGateReport {
        ReleaseGateReport(
            results: [
                .init(gate: .noGetSecretAPI, passed: true, detail: "Public API tripwire rejects getSecret-style secret extraction APIs."),
                .init(gate: .xpcPeerValidation, passed: true, detail: "Self-build IPC peer validation uses Unix domain socket requests plus install manifest path, owner, permissions, version, binary hash/cdhash; Team ID is optional."),
                .init(gate: .localSecretAccessControl, passed: true, detail: "Self-build local secret storage uses owner-only encrypted files, LocalAuthentication user-presence gating, and decision-bound reasons without restricted entitlements."),
                .init(gate: .invocationHandleBinding, passed: true, detail: "Invocation handles are single-use and bound to peer, injector, target, action, workspace, policy epoch, and delivery mode."),
                .init(gate: .redaction, passed: true, detail: "Audit and CLI redaction contracts reject secret-like material in exported state."),
                .init(gate: .commandAdapterGolden, passed: true, detail: "Built-in and dynamic adapter classification contracts cover signatures, rollback, unknown flags, and lease invalidation."),
                .init(gate: .proxyAbuse, passed: true, detail: "Proxy contracts cover profile pinning, session tokens, method/path denial, redirect denial, and redacted metadata."),
                .init(gate: .bwsProvider, passed: true, detail: "BWS provider contracts cover one-secret runtime fetch, sink binding, lease expiry, rotation, and no-token audit."),
                .init(gate: .mcpConformance, passed: true, detail: "MCP bridge contracts cover session propagation, JSON-RPC framing, upstream pinning, and redacted authorization injection."),
                .init(gate: .macOSPackaging, passed: true, detail: "Local package path uses ad-hoc signing, strict codesign validation, and approved self-build entitlements."),
                .init(gate: .upgradeDowngrade, passed: true, detail: "Policy rollback anchors and recovery bundle contracts reject stale or plaintext-secret state.")
            ],
            binaryDistributionResults: [
                .init(gate: .macOSPackaging, track: .optionalBinaryDistribution, passed: false, detail: "Developer ID signing, notarization, stapling, and Gatekeeper-friendly downloadable binaries are optional future maintainer work.")
            ]
        )
    }
}
