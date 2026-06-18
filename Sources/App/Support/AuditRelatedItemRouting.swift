import AgenticFortressCore

enum AuditRelatedItemRoute: Equatable {
    case cli(String)
    case proxy(String)
    case bws(String)
    case mcp(String)

    var title: String {
        switch self {
        case .cli:
            "Open CLI Registration"
        case .proxy:
            "Open Proxy Profile"
        case .bws:
            "Open BWS Binding"
        case .mcp:
            "Open MCP Profile"
        }
    }
}

enum AuditRelatedItemRouter {
    static func route(for event: AuditEventSummary?, snapshot: ManagementSnapshot?) -> AuditRelatedItemRoute? {
        guard let event, let snapshot else { return nil }
        switch event.flow {
        case .cliEnv:
            return snapshot.cliRegistrations.contains(where: { $0.name == event.subjectID }) ? .cli(event.subjectID) : nil
        case .apiProxy:
            guard let profile = snapshot.proxyProfiles.first(where: { $0.name == event.subjectID || $0.secretAlias == event.secretID }) else { return nil }
            return .proxy(profile.name)
        case .bwsProvider:
            guard let binding = snapshot.bwsBindings.first(where: { $0.alias == event.subjectID || $0.alias == event.secretID }) else { return nil }
            return .bws(binding.alias)
        case .remoteMCP:
            return snapshot.mcpProfiles.contains(where: { $0.name == event.subjectID }) ? .mcp(event.subjectID) : nil
        case .remoteSSHStdin, .cloudNativeIdentity:
            return nil
        }
    }
}
