import AgenticFortressCore
import Foundation

protocol AgenticFortressClient: Sendable {
    func health() async throws
    func loadSnapshot() async throws -> ManagementSnapshot
    func registerCLI(_ request: ManagementCLIRegistrationRequest) async throws -> CLIRegistrationSummary
    func unregisterCLI(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary
    func refreshCLITrust(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary
    func replaceSecret(_ request: ManagementSecretReplacementRequest) async throws -> ManagedSecretSummary
    func deleteSecret(_ request: ManagementSecretDeletionRequest) async throws
    func upsertProxyProfile(_ profile: ProxyProfile) async throws -> ProxyProfileSummary
    func deleteProxyProfile(_ request: ManagementNameRequest) async throws
    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary
    func deleteMCPProfile(_ request: ManagementNameRequest) async throws
    func upsertBWSBinding(_ binding: BWSSecretBinding) async throws -> BWSBindingSummary
    func deleteBWSBinding(_ request: ManagementNameRequest) async throws
    func installAdapter(_ payload: AdapterPackPayload) async throws -> AdapterSummary
    func revokeAdapter(_ request: ManagementNameRequest) async throws
    func updateCommandPolicy(_ request: ManagementCommandPolicyUpdateRequest) async throws -> CommandPolicySummary
    func createProxySession(_ request: ManagementProxySessionRequest) async throws -> ManagementProxySessionResponse
    func clearUnlockGrants() async throws
    func exportRedactedAuditJSON() async throws -> String
}

struct DefaultAgenticFortressClient {
    static func make() -> any AgenticFortressClient {
        IPCAgenticFortressClient()
    }
}

struct IPCAgenticFortressClient: AgenticFortressClient {
    var socketPath: String
    var peer: SelfBuildPeerIdentity

    init() {
        let paths = Self.defaultPaths()
        self.socketPath = paths.socketPath
        self.peer = (try? Self.defaultPeer()) ?? Self.untrustedPeer()
    }

    func health() async throws {
        try await sendWithoutPayloadResponse(operation: .health, payload: EmptyPayload())
    }

    func loadSnapshot() async throws -> ManagementSnapshot {
        try await send(operation: .loadManagementSnapshot, payload: EmptyPayload(), response: ManagementSnapshot.self)
    }

    func registerCLI(_ request: ManagementCLIRegistrationRequest) async throws -> CLIRegistrationSummary {
        try await send(operation: .registerCLI, payload: request, response: CLIRegistrationSummary.self)
    }

    func unregisterCLI(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary {
        try await send(operation: .unregisterCLI, payload: request, response: CLIRegistrationSummary.self)
    }

    func refreshCLITrust(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary {
        try await send(operation: .refreshCLITrust, payload: request, response: CLIRegistrationSummary.self)
    }

    func replaceSecret(_ request: ManagementSecretReplacementRequest) async throws -> ManagedSecretSummary {
        try await send(operation: .replaceSecret, payload: request, response: ManagedSecretSummary.self)
    }

    func deleteSecret(_ request: ManagementSecretDeletionRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .deleteSecret, payload: request)
    }

    func upsertProxyProfile(_ profile: ProxyProfile) async throws -> ProxyProfileSummary {
        try await send(operation: .upsertProxyProfile, payload: profile, response: ProxyProfileSummary.self)
    }

    func deleteProxyProfile(_ request: ManagementNameRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .deleteProxyProfile, payload: request)
    }

    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary {
        try await send(operation: .upsertMCPProfile, payload: profile, response: MCPProfileSummary.self)
    }

    func deleteMCPProfile(_ request: ManagementNameRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .deleteMCPProfile, payload: request)
    }

    func upsertBWSBinding(_ binding: BWSSecretBinding) async throws -> BWSBindingSummary {
        try await send(operation: .upsertBWSBinding, payload: binding, response: BWSBindingSummary.self)
    }

    func deleteBWSBinding(_ request: ManagementNameRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .deleteBWSBinding, payload: request)
    }

    func installAdapter(_ payload: AdapterPackPayload) async throws -> AdapterSummary {
        try await send(operation: .installAdapter, payload: payload, response: AdapterSummary.self)
    }

    func revokeAdapter(_ request: ManagementNameRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .revokeAdapter, payload: request)
    }

    func updateCommandPolicy(_ request: ManagementCommandPolicyUpdateRequest) async throws -> CommandPolicySummary {
        try await send(operation: .updateCommandPolicy, payload: request, response: CommandPolicySummary.self)
    }

    func createProxySession(_ request: ManagementProxySessionRequest) async throws -> ManagementProxySessionResponse {
        try await send(operation: .createManagedProxySession, payload: request, response: ManagementProxySessionResponse.self)
    }

    func clearUnlockGrants() async throws {
        try await sendWithoutPayloadResponse(operation: .clearUnlockGrants, payload: EmptyPayload())
    }

    func exportRedactedAuditJSON() async throws -> String {
        let result = try await send(operation: .exportRedactedAudit, payload: EmptyPayload(), response: [String: String].self)
        return result["audit"] ?? "[]"
    }

    private func sendWithoutPayloadResponse<T: Encodable & Sendable>(operation: CoreIPCOperation, payload: T) async throws {
        let response = try sendRaw(operation: operation, payload: payload)
        guard response.ok else {
            throw IPCClientError.response(response.error ?? "unknown IPC error")
        }
    }

    private func send<T: Encodable & Sendable, R: Decodable & Sendable>(operation: CoreIPCOperation, payload: T, response: R.Type) async throws -> R {
        let ipcResponse = try sendRaw(operation: operation, payload: payload)
        guard ipcResponse.ok else {
            throw IPCClientError.response(ipcResponse.error ?? "unknown IPC error")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(response, from: ipcResponse.payload)
    }

    private func sendRaw<T: Encodable & Sendable>(operation: CoreIPCOperation, payload: T) throws -> CoreIPCResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let request = CoreIPCRequest(
            requestID: "ui_" + UUID().uuidString,
            operation: operation,
            peer: peer,
            payload: try encoder.encode(payload)
        )
        return try UnixDomainSocketIPCClient(socketPath: socketPath).send(request)
    }

    static func defaultPaths() -> (socketPath: String, manifestPath: String?) {
        let environment = ProcessInfo.processInfo.environment
        if let socket = environment["AGENTIC_FORTRESS_CORE_SOCKET"], !socket.isEmpty {
            return (socket, environment["AGENTIC_FORTRESS_INSTALL_MANIFEST"])
        }
        if let prefix = installPrefixFromBundle() {
            return (
                Self.defaultRuntimeSocketPath(),
                prefix.appendingPathComponent("var/agentic-fortress/install-manifest.json").path
            )
        }
        return (
            AgenticFortressStateLayout.defaultStateDirectory().appendingPathComponent("core.sock").path,
            nil
        )
    }

    static func defaultRuntimeSocketPath() -> String {
        "/tmp/agentic-fortress-\(getuid())/core.sock"
    }

    static func installPrefixFromBundle() -> URL? {
        let components = Bundle.main.bundleURL.standardizedFileURL.pathComponents
        guard let applicationsIndex = components.lastIndex(of: "Applications"), applicationsIndex > 0 else {
            return nil
        }
        return URL(fileURLWithPath: "/" + components[1..<applicationsIndex].joined(separator: "/"), isDirectory: true)
    }

    static func defaultPeer() throws -> SelfBuildPeerIdentity {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let path = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        return try SelfBuildPeerValidator.identity(helperName: "AgenticFortress", path: path, version: version)
    }

    static func untrustedPeer() -> SelfBuildPeerIdentity {
        SelfBuildPeerIdentity(
            helperName: "AgenticFortress",
            resolvedPath: CommandLine.arguments.first ?? "AgenticFortress",
            ownerUserID: getuid(),
            fileMode: 0,
            parentMode: 0,
            version: "0.1.0",
            binarySHA256: "missing",
            debugSigned: true
        )
    }
}

private struct EmptyPayload: Codable, Sendable {}

private enum IPCClientError: Error, CustomStringConvertible {
    case response(String)

    var description: String {
        switch self {
        case .response(let message):
            message
        }
    }
}

struct StubAgenticFortressClient: AgenticFortressClient {
    var snapshot: ManagementSnapshot

    func health() async throws {}
    func loadSnapshot() async throws -> ManagementSnapshot { snapshot }
    func registerCLI(_ request: ManagementCLIRegistrationRequest) async throws -> CLIRegistrationSummary { snapshot.cliRegistrations.first! }
    func unregisterCLI(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary { snapshot.cliRegistrations.first! }
    func refreshCLITrust(_ request: ManagementNameRequest) async throws -> CLIRegistrationSummary { snapshot.cliRegistrations.first! }
    func replaceSecret(_ request: ManagementSecretReplacementRequest) async throws -> ManagedSecretSummary { snapshot.secrets.first! }
    func deleteSecret(_ request: ManagementSecretDeletionRequest) async throws {}
    func upsertProxyProfile(_ profile: ProxyProfile) async throws -> ProxyProfileSummary { ProxyProfileSummary(profile: profile) }
    func deleteProxyProfile(_ request: ManagementNameRequest) async throws {}
    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary { MCPProfileSummary(profile: profile) }
    func deleteMCPProfile(_ request: ManagementNameRequest) async throws {}
    func upsertBWSBinding(_ binding: BWSSecretBinding) async throws -> BWSBindingSummary {
        BWSBindingSummary(binding: binding, policy: BWSProviderLeasePolicy.policy(for: ProviderEnvironment(rawValue: binding.environment) ?? .dev))
    }
    func deleteBWSBinding(_ request: ManagementNameRequest) async throws {}
    func installAdapter(_ payload: AdapterPackPayload) async throws -> AdapterSummary {
        AdapterSummary(payload: payload, adapterHash: AdapterCanonicalizer.hash(payload), installedAt: Date())
    }
    func revokeAdapter(_ request: ManagementNameRequest) async throws {}
    func updateCommandPolicy(_ request: ManagementCommandPolicyUpdateRequest) async throws -> CommandPolicySummary {
        CommandPolicySummary(config: request.config)
    }
    func createProxySession(_ request: ManagementProxySessionRequest) async throws -> ManagementProxySessionResponse {
        let profile = ProxyProfile(name: request.profileName, upstreamOrigin: URL(string: "https://api.example.com")!, allowedPathPrefixes: ["/v1/"], allowedMethods: ["GET"], secretAlias: "example.secret")
        let (session, token) = ProxyAuthorizer().createSession(profile: profile, bindPort: request.bindPort)
        return ManagementProxySessionResponse(session: session, oneTimeToken: token)
    }
    func clearUnlockGrants() async throws {}
    func exportRedactedAuditJSON() async throws -> String { "[]" }
}
