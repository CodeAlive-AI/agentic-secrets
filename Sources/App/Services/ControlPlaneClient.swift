import AgenticSecretsBroker
import Foundation

protocol ControlPlaneClient: Sendable {
    func health() async throws
    func loadSnapshot() async throws -> ControlPlaneSnapshot
    func registerCLI(_ request: ControlPlaneCommandLineToolRegistrationRequest) async throws -> CLIRegistrationSummary
    func unregisterCLI(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary
    func refreshCLITrust(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary
    func replaceSecret(_ request: ControlPlaneSecretReplacementRequest) async throws -> ManagedSecretSummary
    func deleteSecret(_ request: ControlPlaneSecretDeletionRequest) async throws
    func upsertAPISessionProfile(_ profile: APISessionProfile) async throws -> APISessionProfileSummary
    func deleteAPISessionProfile(_ request: ControlPlaneNameRequest) async throws
    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary
    func deleteMCPProfile(_ request: ControlPlaneNameRequest) async throws
    func upsertBitwardenBinding(_ binding: BitwardenSecretBinding) async throws -> BitwardenBindingSummary
    func deleteBitwardenBinding(_ request: ControlPlaneNameRequest) async throws
    func installAdapter(_ payload: CommandPolicyPackPayload) async throws -> PolicyPackSummary
    func revokeAdapter(_ request: ControlPlaneNameRequest) async throws
    func updateCommandPolicy(_ request: ControlPlaneCommandPolicyUpdateRequest) async throws -> CommandPolicySummary
    func createAPISession(_ request: ControlPlaneAPISessionRequest) async throws -> ControlPlaneAPISessionResponse
    func clearDeliveryGrants() async throws
    func exportRedactedAuditJSON() async throws -> String
}

struct DefaultControlPlaneClient {
    static func make() -> any ControlPlaneClient {
        IPCControlPlaneClient()
    }
}

struct IPCControlPlaneClient: ControlPlaneClient {
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

    func loadSnapshot() async throws -> ControlPlaneSnapshot {
        try await send(operation: .loadControlPlaneSnapshot, payload: EmptyPayload(), response: ControlPlaneSnapshot.self)
    }

    func registerCLI(_ request: ControlPlaneCommandLineToolRegistrationRequest) async throws -> CLIRegistrationSummary {
        try await send(operation: .registerCLI, payload: request, response: CLIRegistrationSummary.self)
    }

    func unregisterCLI(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary {
        try await send(operation: .unregisterCLI, payload: request, response: CLIRegistrationSummary.self)
    }

    func refreshCLITrust(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary {
        try await send(operation: .refreshCLITrust, payload: request, response: CLIRegistrationSummary.self)
    }

    func replaceSecret(_ request: ControlPlaneSecretReplacementRequest) async throws -> ManagedSecretSummary {
        try await send(operation: .replaceSecret, payload: request, response: ManagedSecretSummary.self)
    }

    func deleteSecret(_ request: ControlPlaneSecretDeletionRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .deleteSecret, payload: request)
    }

    func upsertAPISessionProfile(_ profile: APISessionProfile) async throws -> APISessionProfileSummary {
        try await send(operation: .upsertAPISessionProfile, payload: profile, response: APISessionProfileSummary.self)
    }

    func deleteAPISessionProfile(_ request: ControlPlaneNameRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .deleteAPISessionProfile, payload: request)
    }

    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary {
        try await send(operation: .upsertMCPProfile, payload: profile, response: MCPProfileSummary.self)
    }

    func deleteMCPProfile(_ request: ControlPlaneNameRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .deleteMCPProfile, payload: request)
    }

    func upsertBitwardenBinding(_ binding: BitwardenSecretBinding) async throws -> BitwardenBindingSummary {
        try await send(operation: .upsertBitwardenBinding, payload: binding, response: BitwardenBindingSummary.self)
    }

    func deleteBitwardenBinding(_ request: ControlPlaneNameRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .deleteBitwardenBinding, payload: request)
    }

    func installAdapter(_ payload: CommandPolicyPackPayload) async throws -> PolicyPackSummary {
        try await send(operation: .installAdapter, payload: payload, response: PolicyPackSummary.self)
    }

    func revokeAdapter(_ request: ControlPlaneNameRequest) async throws {
        try await sendWithoutPayloadResponse(operation: .revokeAdapter, payload: request)
    }

    func updateCommandPolicy(_ request: ControlPlaneCommandPolicyUpdateRequest) async throws -> CommandPolicySummary {
        try await send(operation: .updateCommandPolicy, payload: request, response: CommandPolicySummary.self)
    }

    func createAPISession(_ request: ControlPlaneAPISessionRequest) async throws -> ControlPlaneAPISessionResponse {
        try await send(operation: .createManagedAPISession, payload: request, response: ControlPlaneAPISessionResponse.self)
    }

    func clearDeliveryGrants() async throws {
        try await sendWithoutPayloadResponse(operation: .clearDeliveryGrants, payload: EmptyPayload())
    }

    func exportRedactedAuditJSON() async throws -> String {
        let result = try await send(operation: .exportRedactedAudit, payload: EmptyPayload(), response: [String: String].self)
        return result["audit"] ?? "[]"
    }

    private func sendWithoutPayloadResponse<T: Encodable & Sendable>(operation: BrokerIPCOperation, payload: T) async throws {
        let response = try sendRaw(operation: operation, payload: payload)
        guard response.ok else {
            throw IPCClientError.response(response.error ?? "unknown IPC error")
        }
    }

    private func send<T: Encodable & Sendable, R: Decodable & Sendable>(operation: BrokerIPCOperation, payload: T, response: R.Type) async throws -> R {
        let ipcResponse = try sendRaw(operation: operation, payload: payload)
        guard ipcResponse.ok else {
            throw IPCClientError.response(ipcResponse.error ?? "unknown IPC error")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(response, from: ipcResponse.payload)
    }

    private func sendRaw<T: Encodable & Sendable>(operation: BrokerIPCOperation, payload: T) throws -> BrokerIPCResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let request = BrokerIPCRequest(
            requestID: "ui_" + UUID().uuidString,
            operation: operation,
            peer: peer,
            payload: try encoder.encode(payload)
        )
        return try UnixDomainSocketIPCClient(socketPath: socketPath).send(request)
    }

    static func defaultPaths() -> (socketPath: String, manifestPath: String?) {
        let environment = ProcessInfo.processInfo.environment
        if let socket = environment["AGENTIC_SECRETS_CORE_SOCKET"], !socket.isEmpty {
            return (socket, environment["AGENTIC_SECRETS_INSTALL_MANIFEST"])
        }
        if let prefix = installPrefixFromBundle() {
            return (
                Self.defaultRuntimeSocketPath(),
                prefix.appendingPathComponent("var/agentic-secrets/install-manifest.json").path
            )
        }
        return (
            LocalInstallLayout.defaultStateDirectory().appendingPathComponent("core.sock").path,
            nil
        )
    }

    static func defaultRuntimeSocketPath() -> String {
        "/tmp/agentic-secrets-\(getuid())/core.sock"
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
        return try SelfBuildPeerValidator.identity(helperName: "AgenticSecrets", path: path, version: version)
    }

    static func untrustedPeer() -> SelfBuildPeerIdentity {
        SelfBuildPeerIdentity(
            helperName: "AgenticSecrets",
            resolvedPath: CommandLine.arguments.first ?? "AgenticSecrets",
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

struct StubControlPlaneClient: ControlPlaneClient {
    var snapshot: ControlPlaneSnapshot

    func health() async throws {}
    func loadSnapshot() async throws -> ControlPlaneSnapshot { snapshot }
    func registerCLI(_ request: ControlPlaneCommandLineToolRegistrationRequest) async throws -> CLIRegistrationSummary { snapshot.cliRegistrations.first! }
    func unregisterCLI(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary { snapshot.cliRegistrations.first! }
    func refreshCLITrust(_ request: ControlPlaneNameRequest) async throws -> CLIRegistrationSummary { snapshot.cliRegistrations.first! }
    func replaceSecret(_ request: ControlPlaneSecretReplacementRequest) async throws -> ManagedSecretSummary { snapshot.secrets.first! }
    func deleteSecret(_ request: ControlPlaneSecretDeletionRequest) async throws {}
    func upsertAPISessionProfile(_ profile: APISessionProfile) async throws -> APISessionProfileSummary { APISessionProfileSummary(profile: profile) }
    func deleteAPISessionProfile(_ request: ControlPlaneNameRequest) async throws {}
    func upsertMCPProfile(_ profile: MCPUpstreamProfile) async throws -> MCPProfileSummary { MCPProfileSummary(profile: profile) }
    func deleteMCPProfile(_ request: ControlPlaneNameRequest) async throws {}
    func upsertBitwardenBinding(_ binding: BitwardenSecretBinding) async throws -> BitwardenBindingSummary {
        BitwardenBindingSummary(binding: binding, policy: BitwardenProviderLeasePolicy.policy(for: ProviderEnvironment(rawValue: binding.environment) ?? .dev))
    }
    func deleteBitwardenBinding(_ request: ControlPlaneNameRequest) async throws {}
    func installAdapter(_ payload: CommandPolicyPackPayload) async throws -> PolicyPackSummary {
        PolicyPackSummary(payload: payload, policyPackHash: AdapterCanonicalizer.hash(payload), installedAt: Date())
    }
    func revokeAdapter(_ request: ControlPlaneNameRequest) async throws {}
    func updateCommandPolicy(_ request: ControlPlaneCommandPolicyUpdateRequest) async throws -> CommandPolicySummary {
        CommandPolicySummary(config: request.config)
    }
    func createAPISession(_ request: ControlPlaneAPISessionRequest) async throws -> ControlPlaneAPISessionResponse {
        let profile = APISessionProfile(name: request.profileName, upstreamOrigin: URL(string: "https://api.example.com")!, allowedPathPrefixes: ["/v1/"], allowedMethods: ["GET"], secretAlias: "example.secret")
        let (session, token) = APISessionAuthorizer().createSession(profile: profile, bindPort: request.bindPort)
        return ControlPlaneAPISessionResponse(session: session, oneTimeToken: token)
    }
    func clearDeliveryGrants() async throws {}
    func exportRedactedAuditJSON() async throws -> String { "[]" }
}
