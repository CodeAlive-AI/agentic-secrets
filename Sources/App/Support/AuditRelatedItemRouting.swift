import AgenticSecretsBroker

enum AuditRelatedItemRoute: Equatable {
    case cli(String)
    case bitwardenBinding(String)
    case mcp(String)

    var title: String {
        switch self {
        case .cli:
            "Open CLI Registration"
        case .bitwardenBinding:
            "Open Bitwarden Provider Binding"
        case .mcp:
            "Open MCP Proxy"
        }
    }
}

enum AuditRelatedItemRouter {
    static func route(for event: AuditEventSummary?, snapshot: ControlPlaneSnapshot?) -> AuditRelatedItemRoute? {
        guard let event, let snapshot else { return nil }
        switch event.flow {
        case .cliEnv:
            return snapshot.cliRegistrations.contains(where: { $0.name == event.subjectID }) ? .cli(event.subjectID) : nil
        case .apiSession:
            return nil
        case .bitwardenProvider:
            guard let binding = snapshot.bitwardenBindings.first(where: { $0.alias == event.subjectID || $0.alias == event.secretID }) else { return nil }
            return .bitwardenBinding(binding.alias)
        case .remoteMCP:
            return snapshot.mcpProfiles.contains(where: { $0.name == event.subjectID }) ? .mcp(event.subjectID) : nil
        case .remoteSSHStdin, .cloudNativeIdentity:
            return nil
        }
    }
}
