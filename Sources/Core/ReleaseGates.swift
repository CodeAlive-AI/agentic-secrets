import Foundation

public enum ReleaseGate: String, CaseIterable, Codable, Sendable {
    case noGetSecretAPI = "no-getSecret-api"
    case xpcPeerValidation = "xpc-peer-validation"
    case keychainAccessControl = "keychain-access-control"
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
    public var passed: Bool
    public var detail: String
}

public struct ReleaseGateReport: Codable, Equatable, Sendable {
    public var results: [ReleaseGateResult]

    public init(results: [ReleaseGateResult]) {
        self.results = results
    }

    public var canRelease: Bool {
        results.allSatisfy(\.passed)
    }

    private enum CodingKeys: String, CodingKey {
        case results
        case canRelease
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.results = try container.decode([ReleaseGateResult].self, forKey: .results)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(results, forKey: .results)
        try container.encode(canRelease, forKey: .canRelease)
    }
}

public struct ReleaseGateRunner: Sendable {
    public init() {}

    public func staticReport() -> ReleaseGateReport {
        ReleaseGateReport(results: [
            .init(gate: .noGetSecretAPI, passed: true, detail: "Public API tripwire rejects getSecret-style secret extraction APIs."),
            .init(gate: .xpcPeerValidation, passed: false, detail: "Peer identity model is covered by contracts, but production NSXPC listener/client wiring is not implemented yet."),
            .init(gate: .keychainAccessControl, passed: false, detail: "Keychain query/access-control contracts exist, but production app identity, access group, and user-prompt flow are not end-to-end verified."),
            .init(gate: .invocationHandleBinding, passed: true, detail: "Invocation handles are single-use and bound to peer, injector, target, action, workspace, policy epoch, and delivery mode."),
            .init(gate: .redaction, passed: true, detail: "Audit and CLI redaction contracts reject secret-like material in exported state."),
            .init(gate: .commandAdapterGolden, passed: true, detail: "Built-in and dynamic adapter classification contracts cover signatures, rollback, unknown flags, and lease invalidation."),
            .init(gate: .proxyAbuse, passed: true, detail: "Proxy contracts cover profile pinning, session tokens, method/path denial, redirect denial, and redacted metadata."),
            .init(gate: .bwsProvider, passed: true, detail: "BWS provider contracts cover one-secret runtime fetch, sink binding, lease expiry, rotation, and no-token audit."),
            .init(gate: .mcpConformance, passed: true, detail: "MCP bridge contracts cover session propagation, JSON-RPC framing, upstream pinning, and redacted authorization injection."),
            .init(gate: .macOSPackaging, passed: false, detail: "Ad-hoc Tahoe packaging validates locally; Developer ID signing, notarization, and production entitlement review remain external release gates."),
            .init(gate: .upgradeDowngrade, passed: true, detail: "Policy rollback anchors and recovery bundle contracts reject stale or plaintext-secret state.")
        ])
    }
}
