import Foundation

public enum ManagementHealthStatus: String, Codable, Equatable, Sendable {
    case ok
    case attention
    case locked
}

public struct ManagedSecretSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var environment: String
    public var storeKind: String
    public var externalIDDigest: String

    public init(alias: String, environment: String, storeKind: String, externalIDDigest: String) {
        self.alias = alias
        self.environment = environment
        self.storeKind = storeKind
        self.externalIDDigest = externalIDDigest
    }
}

public struct CLIRegistrationSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var targetPath: String
    public var targetResolvedPath: String?
    public var targetIdentity: String?
    public var targetCDHash: String?
    public var targetDesignatedRequirement: String?
    public var targetSigningIdentifier: String?
    public var targetTeamIdentifier: String?
    public var environmentBindings: [CLIEnvironmentBinding]
    public var registeredAt: Date
    public var trustStatus: String
    public var shimStatus: String

    public init(registration: CLIAppRegistration, shimStatus: String = "unknown") {
        self.name = registration.name
        self.targetPath = registration.targetPath
        self.targetResolvedPath = registration.targetResolvedPath
        self.targetIdentity = registration.targetIdentity
        self.targetCDHash = registration.targetCDHash
        self.targetDesignatedRequirement = registration.targetDesignatedRequirement
        self.targetSigningIdentifier = registration.targetSigningIdentifier
        self.targetTeamIdentifier = registration.targetTeamIdentifier
        self.environmentBindings = registration.environmentBindings
        self.registeredAt = registration.registeredAt
        self.trustStatus = registration.targetIdentity == nil && registration.targetDesignatedRequirement == nil ? "unsealed" : "trusted"
        self.shimStatus = shimStatus
    }
}

public struct ProxyProfileSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var upstreamOrigin: URL
    public var allowedPathPrefixes: [String]
    public var allowedMethods: [String]
    public var secretAlias: String
    public var tokenTTLSeconds: TimeInterval

    public init(profile: ProxyProfile) {
        self.name = profile.name
        self.upstreamOrigin = profile.upstreamOrigin
        self.allowedPathPrefixes = profile.allowedPathPrefixes
        self.allowedMethods = profile.allowedMethods.sorted()
        self.secretAlias = profile.secretAlias
        self.tokenTTLSeconds = profile.tokenTTLSeconds
    }
}

public struct MCPProfileSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var origin: URL
    public var authorizationHeaderName: String
    public var allowedPathPrefixes: [String]
    public var allowCrossOriginRedirects: Bool

    public init(profile: MCPUpstreamProfile) {
        self.name = profile.name
        self.origin = profile.origin
        self.authorizationHeaderName = profile.authorizationHeaderName
        self.allowedPathPrefixes = profile.allowedPathPrefixes
        self.allowCrossOriginRedirects = profile.allowCrossOriginRedirects
    }
}

public struct BWSBindingSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var projectID: String
    public var secretIDDigest: String
    public var environment: String
    public var maxLeaseSeconds: TimeInterval
    public var requiresPerFetchApproval: Bool

    public init(binding: BWSSecretBinding, policy: BWSProviderLeasePolicy) {
        self.alias = binding.alias
        self.projectID = binding.projectID
        self.secretIDDigest = "sha256:" + shortDigest(binding.secretID, length: 16)
        self.environment = binding.environment
        self.maxLeaseSeconds = policy.maxLeaseSeconds
        self.requiresPerFetchApproval = policy.requiresPerFetchApproval
    }
}

public struct AdapterSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { adapterID }
    public var adapterID: String
    public var adapterVersion: Int
    public var cliName: String
    public var publisher: String
    public var adapterHash: String
    public var installedAt: Date?
    public var revokedAt: Date?
    public var ruleCount: Int

    public init(payload: AdapterPackPayload, adapterHash: String, installedAt: Date? = nil, revokedAt: Date? = nil) {
        self.adapterID = payload.adapterID
        self.adapterVersion = payload.adapterVersion
        self.cliName = payload.cliName
        self.publisher = payload.publisher
        self.adapterHash = adapterHash
        self.installedAt = installedAt
        self.revokedAt = revokedAt
        self.ruleCount = payload.rules.count
    }
}

public struct UnlockGrantSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { scopeDigest }
    public var scopeDigest: String
    public var subject: String?
    public var actionClass: String?
    public var risk: RiskLevel?
    public var originHint: String?
    public var provenanceConfidence: ProvenanceConfidence?
    public var grantedAt: Date
    public var expiresAt: Date

    public init(scopeDigest: String, scope: CLIUnlockScope?, grantedAt: Date, expiresAt: Date) {
        self.scopeDigest = scopeDigest
        self.subject = scope?.subject
        self.actionClass = scope?.actionClass
        self.risk = scope?.risk
        self.originHint = scope?.originHint
        self.provenanceConfidence = scope?.provenanceConfidence
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
    }
}

public struct AuditEventSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(time.timeIntervalSince1970)-\(decisionDigest)-\(outcome)" }
    public var event: String
    public var decision: String
    public var decisionDigest: String
    public var flow: DeliveryFlow
    public var subjectID: String
    public var secretID: String
    public var actionClass: String
    public var targetIdentity: String
    public var workspaceHash: String
    public var originHint: String
    public var provenanceConfidence: ProvenanceConfidence
    public var delivery: DeliveryMode
    public var policyEpoch: Int
    public var approval: String
    public var outcome: String
    public var time: Date

    public init(event: AuditEvent) {
        self.event = event.event
        self.decision = event.decision
        self.decisionDigest = event.decisionDigest
        self.flow = event.flow
        self.subjectID = event.subjectID
        self.secretID = event.secretID
        self.actionClass = event.actionClass
        self.targetIdentity = event.targetIdentity
        self.workspaceHash = event.workspaceHash
        self.originHint = event.originHint
        self.provenanceConfidence = event.provenanceConfidence
        self.delivery = event.delivery
        self.policyEpoch = event.policyEpoch
        self.approval = event.approval
        self.outcome = event.outcome
        self.time = event.time
    }
}

public struct SecurityHealthSummary: Codable, Equatable, Sendable {
    public var status: ManagementHealthStatus
    public var attentionItems: [String]
    public var localSelfBuildReady: Bool
    public var runtimeMajor: Int
    public var requiredSDKMajor: Int
    public var protocolVersion: Int

    public init(status: ManagementHealthStatus, attentionItems: [String], localSelfBuildReady: Bool, runtimeMajor: Int, requiredSDKMajor: Int, protocolVersion: Int = CoreIPC.protocolVersion) {
        self.status = status
        self.attentionItems = attentionItems
        self.localSelfBuildReady = localSelfBuildReady
        self.runtimeMajor = runtimeMajor
        self.requiredSDKMajor = requiredSDKMajor
        self.protocolVersion = protocolVersion
    }
}

public struct CommandPolicySummary: Codable, Equatable, Sendable {
    public var destructiveTerms: [String]
    public var forbiddenTerms: [String]

    public init(config: CommandPolicyConfig) {
        self.destructiveTerms = CommandPolicyConfig.normalizedTerms(config.destructiveTerms)
        self.forbiddenTerms = CommandPolicyConfig.normalizedTerms(config.forbiddenTerms)
    }
}

public struct ManagementSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var stateDirectory: String
    public var configPath: String
    public var cliRegistrations: [CLIRegistrationSummary]
    public var secrets: [ManagedSecretSummary]
    public var proxyProfiles: [ProxyProfileSummary]
    public var mcpProfiles: [MCPProfileSummary]
    public var bwsBindings: [BWSBindingSummary]
    public var adapters: [AdapterSummary]
    public var unlockGrants: [UnlockGrantSummary]
    public var auditEvents: [AuditEventSummary]
    public var securityHealth: SecurityHealthSummary
    public var commandPolicy: CommandPolicySummary

    public init(
        generatedAt: Date,
        stateDirectory: String,
        configPath: String,
        cliRegistrations: [CLIRegistrationSummary],
        secrets: [ManagedSecretSummary],
        proxyProfiles: [ProxyProfileSummary],
        mcpProfiles: [MCPProfileSummary],
        bwsBindings: [BWSBindingSummary],
        adapters: [AdapterSummary],
        unlockGrants: [UnlockGrantSummary],
        auditEvents: [AuditEventSummary],
        securityHealth: SecurityHealthSummary,
        commandPolicy: CommandPolicySummary
    ) {
        self.generatedAt = generatedAt
        self.stateDirectory = stateDirectory
        self.configPath = configPath
        self.cliRegistrations = cliRegistrations
        self.secrets = secrets
        self.proxyProfiles = proxyProfiles
        self.mcpProfiles = mcpProfiles
        self.bwsBindings = bwsBindings
        self.adapters = adapters
        self.unlockGrants = unlockGrants
        self.auditEvents = auditEvents
        self.securityHealth = securityHealth
        self.commandPolicy = commandPolicy
    }
}

public struct ManagementCLIRegistrationRequest: Codable, Equatable, Sendable {
    public var name: String
    public var targetPath: String
    public var environmentSecrets: [String: String]

    public init(name: String, targetPath: String, environmentSecrets: [String: String]) {
        self.name = name
        self.targetPath = targetPath
        self.environmentSecrets = environmentSecrets
    }
}

public struct ManagementNameRequest: Codable, Equatable, Sendable {
    public var name: String
    public var deleteSecretMaterial: Bool

    public init(name: String, deleteSecretMaterial: Bool = false) {
        self.name = name
        self.deleteSecretMaterial = deleteSecretMaterial
    }
}

public struct ManagementSecretReplacementRequest: Codable, Equatable, Sendable {
    public var alias: String
    public var value: String
    public var label: String
    public var environment: String

    public init(alias: String, value: String, label: String, environment: String = "management") {
        self.alias = alias
        self.value = value
        self.label = label
        self.environment = environment
    }
}

public struct ManagementSecretDeletionRequest: Codable, Equatable, Sendable {
    public var alias: String
    public var deleteSecretMaterial: Bool

    public init(alias: String, deleteSecretMaterial: Bool) {
        self.alias = alias
        self.deleteSecretMaterial = deleteSecretMaterial
    }
}

public struct ManagementProxySessionRequest: Codable, Equatable, Sendable {
    public var profileName: String
    public var bindPort: Int

    public init(profileName: String, bindPort: Int) {
        self.profileName = profileName
        self.bindPort = bindPort
    }
}

public struct ManagementProxySessionResponse: Codable, Equatable, Sendable {
    public var session: ProxySession
    public var oneTimeToken: String

    public init(session: ProxySession, oneTimeToken: String) {
        self.session = session
        self.oneTimeToken = oneTimeToken
    }
}

public struct ManagementCommandPolicyUpdateRequest: Codable, Equatable, Sendable {
    public var destructiveTerms: [String]
    public var forbiddenTerms: [String]

    public init(destructiveTerms: [String], forbiddenTerms: [String]) {
        self.destructiveTerms = destructiveTerms
        self.forbiddenTerms = forbiddenTerms
    }

    public var config: CommandPolicyConfig {
        CommandPolicyConfig(destructiveTerms: destructiveTerms, forbiddenTerms: forbiddenTerms)
    }
}

public enum ManagementError: Error, Equatable, CustomStringConvertible {
    case missingProfile(String)
    case missingBinding(String)
    case deleteSecretMaterialNotConfirmed
    case unsupportedConfigSchema(Int)
    case rawSecretInResponse

    public var description: String {
        switch self {
        case .missingProfile(let name):
            "No profile found named \(name)."
        case .missingBinding(let name):
            "No binding found named \(name)."
        case .deleteSecretMaterialNotConfirmed:
            "Deleting secret material requires explicit confirmation."
        case .unsupportedConfigSchema(let schema):
            "Unsupported management config schema: \(schema)."
        case .rawSecretInResponse:
            "Management response attempted to include secret-like material."
        }
    }
}

public protocol DeliveryWitness: Sendable {
    func willReplaceSecret(alias: String, environment: String) throws
    func didReplaceSecret(alias: String, environment: String)
}

public struct PermissiveDeliveryWitness: DeliveryWitness {
    public init() {}
    public func willReplaceSecret(alias: String, environment: String) throws {}
    public func didReplaceSecret(alias: String, environment: String) {}
}

public struct CoreManagementService: Sendable {
    public var stateDirectory: URL
    public var configURL: URL
    public var adapterRegistryURL: URL
    public var auditLog: AuditLog
    public var witness: any DeliveryWitness

    public init(
        stateDirectory: URL = AgenticFortressStateLayout.defaultStateDirectory(),
        configURL: URL? = nil,
        adapterRegistryURL: URL? = nil,
        auditLog: AuditLog = AuditLog(),
        witness: any DeliveryWitness = PermissiveDeliveryWitness()
    ) {
        self.stateDirectory = stateDirectory
        self.configURL = configURL ?? stateDirectory.appendingPathComponent("config/agentic-fortress.json")
        self.adapterRegistryURL = adapterRegistryURL ?? stateDirectory.appendingPathComponent("adapters/adapter-registry.json")
        self.auditLog = auditLog
        self.witness = witness
    }

    public func snapshot(now: Date = Date()) throws -> ManagementSnapshot {
        let layout = AgenticFortressStateLayout(stateDirectory: stateDirectory)
        let config = try loadConfig()
        let registry = try layout.registrationService.registryStore.load()
        let secrets = try loadSecretSummaries(layout: layout)
        let adapters = try adapterSummaries()
        let unlockGrants = try loadUnlockGrantSummaries(layout: layout, now: now)
        let health = securityHealth(registrations: registry.registrations.values.map { CLIRegistrationSummary(registration: $0) })
        return try assertRedacted(ManagementSnapshot(
            generatedAt: now,
            stateDirectory: stateDirectory.path,
            configPath: configURL.path,
            cliRegistrations: registry.registrations.values.map { CLIRegistrationSummary(registration: $0) }.sorted { $0.name < $1.name },
            secrets: secrets.sorted { $0.alias < $1.alias },
            proxyProfiles: config.proxyProfiles.map(ProxyProfileSummary.init).sorted { $0.name < $1.name },
            mcpProfiles: config.mcpProfiles.map(MCPProfileSummary.init).sorted { $0.name < $1.name },
            bwsBindings: config.bwsBindings.map {
                BWSBindingSummary(binding: $0, policy: BWSProviderLeasePolicy.policy(for: ProviderEnvironment(rawValue: $0.environment) ?? .dev))
            }.sorted { $0.alias < $1.alias },
            adapters: adapters.sorted { $0.cliName < $1.cliName },
            unlockGrants: unlockGrants.sorted { $0.expiresAt < $1.expiresAt },
            auditEvents: auditLog.snapshot().map(AuditEventSummary.init).sorted { $0.time > $1.time },
            securityHealth: health,
            commandPolicy: CommandPolicySummary(config: config.commandPolicy)
        ))
    }

    @discardableResult
    public func registerCLI(_ request: ManagementCLIRegistrationRequest) throws -> CLIRegistrationSummary {
        let values = request.environmentSecrets.mapValues { SecretMaterial(utf8: $0) }
        let registration = try AgenticFortressStateLayout(stateDirectory: stateDirectory).registrationService.register(
            name: request.name,
            targetPath: request.targetPath,
            environmentValues: values
        )
        return CLIRegistrationSummary(registration: registration)
    }

    @discardableResult
    public func unregisterCLI(_ request: ManagementNameRequest) throws -> CLIRegistrationSummary {
        let registration = try AgenticFortressStateLayout(stateDirectory: stateDirectory).registrationService.unregister(
            name: request.name,
            deleteSecrets: request.deleteSecretMaterial
        )
        return CLIRegistrationSummary(registration: registration)
    }

    @discardableResult
    public func refreshCLITrust(_ request: ManagementNameRequest) throws -> CLIRegistrationSummary {
        let registration = try AgenticFortressStateLayout(stateDirectory: stateDirectory).registrationService.refreshTargetTrust(name: request.name) { _ in }
        return CLIRegistrationSummary(registration: registration)
    }

    public func replaceSecret(_ request: ManagementSecretReplacementRequest) throws -> ManagedSecretSummary {
        try witness.willReplaceSecret(alias: request.alias, environment: request.environment)
        let layout = AgenticFortressStateLayout(stateDirectory: stateDirectory)
        try layout.registrationService.secretStore.store(
            alias: SecretAlias(request.alias),
            material: SecretMaterial(utf8: request.value),
            label: request.label,
            environment: request.environment
        )
        witness.didReplaceSecret(alias: request.alias, environment: request.environment)
        return ManagedSecretSummary(
            alias: request.alias,
            environment: request.environment,
            storeKind: "local-encrypted-file",
            externalIDDigest: "sha256:" + shortDigest(layout.secretStoreURL.path, length: 16)
        )
    }

    public func deleteSecret(_ request: ManagementSecretDeletionRequest) throws {
        guard request.deleteSecretMaterial else {
            throw ManagementError.deleteSecretMaterialNotConfirmed
        }
        try AgenticFortressStateLayout(stateDirectory: stateDirectory).registrationService.secretStore.delete(alias: SecretAlias(request.alias))
    }

    public func upsertProxyProfile(_ profile: ProxyProfile) throws -> ProxyProfileSummary {
        var config = try loadConfig()
        config.proxyProfiles.removeAll { $0.name == profile.name }
        config.proxyProfiles.append(profile)
        try saveConfig(config)
        return ProxyProfileSummary(profile: profile)
    }

    public func deleteProxyProfile(_ request: ManagementNameRequest) throws {
        var config = try loadConfig()
        guard config.proxyProfiles.contains(where: { $0.name == request.name }) else {
            throw ManagementError.missingProfile(request.name)
        }
        config.proxyProfiles.removeAll { $0.name == request.name }
        try saveConfig(config)
    }

    public func upsertMCPProfile(_ profile: MCPUpstreamProfile) throws -> MCPProfileSummary {
        var config = try loadConfig()
        config.mcpProfiles.removeAll { $0.name == profile.name }
        config.mcpProfiles.append(profile)
        try saveConfig(config)
        return MCPProfileSummary(profile: profile)
    }

    public func deleteMCPProfile(_ request: ManagementNameRequest) throws {
        var config = try loadConfig()
        guard config.mcpProfiles.contains(where: { $0.name == request.name }) else {
            throw ManagementError.missingProfile(request.name)
        }
        config.mcpProfiles.removeAll { $0.name == request.name }
        try saveConfig(config)
    }

    public func upsertBWSBinding(_ binding: BWSSecretBinding) throws -> BWSBindingSummary {
        var config = try loadConfig()
        config.bwsBindings.removeAll { $0.alias == binding.alias }
        config.bwsBindings.append(binding)
        try saveConfig(config)
        let environment = ProviderEnvironment(rawValue: binding.environment) ?? .dev
        return BWSBindingSummary(binding: binding, policy: BWSProviderLeasePolicy.policy(for: environment))
    }

    public func deleteBWSBinding(_ request: ManagementNameRequest) throws {
        var config = try loadConfig()
        guard config.bwsBindings.contains(where: { $0.alias == request.name }) else {
            throw ManagementError.missingBinding(request.name)
        }
        config.bwsBindings.removeAll { $0.alias == request.name }
        try saveConfig(config)
    }

    public func createProxySession(_ request: ManagementProxySessionRequest) throws -> ManagementProxySessionResponse {
        let config = try loadConfig()
        guard let profile = config.proxyProfiles.first(where: { $0.name == request.profileName }) else {
            throw ManagementError.missingProfile(request.profileName)
        }
        let (session, token) = ProxyAuthorizer().createSession(profile: profile, bindPort: request.bindPort)
        return ManagementProxySessionResponse(session: session, oneTimeToken: token)
    }

    public func createShimExecPlan(_ request: ShimExecPlanIPCRequest, provenanceConfidence: ProvenanceConfidence) throws -> ShimExecPlanIPCResponse {
        let commandName = URL(fileURLWithPath: request.invokedName).lastPathComponent
        let layout = AgenticFortressStateLayout(stateDirectory: stateDirectory)
        let registration = try layout.registrationService.registration(named: commandName)
        let executableName = URL(fileURLWithPath: registration.targetPath).lastPathComponent
        let commandPolicy = (try? loadConfig().commandPolicy) ?? .default
        let command = CommandClassifier(commandPolicy: commandPolicy).classify(executableName: executableName, arguments: request.arguments)
        let target = try TargetAssessor().assess(path: registration.targetPath)
        try layout.registrationService.validateTargetIdentity(registration: registration, assessedTarget: target)
        let manifests = registration.environmentBindings.map { binding in
            DecisionManifestFactory().make(
                command: command,
                intent: DeliveryIntent(
                    flow: .cliEnv,
                    secretAlias: binding.secretAlias,
                    delivery: .env,
                    environmentName: binding.environmentName,
                    workspace: request.workspace,
                    originHint: request.originHint,
                    provenanceConfidence: provenanceConfidence
                ),
                target: target
            )
        }
        return ShimExecPlanIPCResponse(
            commandName: commandName,
            targetPath: target.resolvedPath,
            argv: [commandName] + request.arguments,
            manifests: manifests,
            provenanceConfidence: provenanceConfidence,
            parentEnvironmentKeys: request.parentEnvironmentKeys
        )
    }

    public func installAdapter(_ payload: AdapterPackPayload) throws -> AdapterSummary {
        try AdapterRegistryStore(url: adapterRegistryURL).install(payload: payload)
        return AdapterSummary(payload: payload, adapterHash: AdapterCanonicalizer.hash(payload), installedAt: Date())
    }

    public func revokeAdapter(_ request: ManagementNameRequest) throws {
        try AdapterRegistryStore(url: adapterRegistryURL).revoke(adapterID: request.name)
    }

    public func updateCommandPolicy(_ request: ManagementCommandPolicyUpdateRequest) throws -> CommandPolicySummary {
        var config = try loadConfig()
        config.commandPolicy = request.config
        try saveConfig(config)
        return CommandPolicySummary(config: config.commandPolicy)
    }

    public func clearUnlockGrants() throws {
        let layout = AgenticFortressStateLayout(stateDirectory: stateDirectory)
        try? FileManager.default.removeItem(at: layout.cliUnlockGrantsURL)
    }

    public func exportRedactedAuditJSON() throws -> String {
        try auditLog.exportRedactedJSON()
    }

    private func loadConfig() throws -> AgenticFortressConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return AgenticFortressConfig()
        }
        let config = try ConfigurationLoader.load(path: configURL.path)
        guard config.schemaVersion == 1 else {
            throw ManagementError.unsupportedConfigSchema(config.schemaVersion)
        }
        return config
    }

    private func saveConfig(_ config: AgenticFortressConfig) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigurationLoader.encode(config).write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func loadSecretSummaries(layout: AgenticFortressStateLayout) throws -> [ManagedSecretSummary] {
        guard FileManager.default.fileExists(atPath: layout.secretStoreURL.path) else {
            return []
        }
        let storeFile = try JSONDecoder().decode(LocalEncryptedSecretFile.self, from: Data(contentsOf: layout.secretStoreURL))
        return storeFile.records.map { alias, record in
            ManagedSecretSummary(
                alias: alias,
                environment: record.binding.environment,
                storeKind: record.binding.storeKind,
                externalIDDigest: "sha256:" + shortDigest(record.binding.externalID, length: 16)
            )
        }
    }

    private func loadUnlockGrantSummaries(layout: AgenticFortressStateLayout, now: Date) throws -> [UnlockGrantSummary] {
        guard FileManager.default.fileExists(atPath: layout.cliUnlockGrantsURL.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CLIUnlockGrantDocument.self, from: Data(contentsOf: layout.cliUnlockGrantsURL))
        return document.grants.values
            .filter { $0.expiresAt >= now }
            .map { UnlockGrantSummary(scopeDigest: $0.scopeDigest, scope: $0.scope, grantedAt: $0.grantedAt, expiresAt: $0.expiresAt) }
    }

    private func adapterSummaries() throws -> [AdapterSummary] {
        let builtIns = [BuiltInAdapterPacks.hcloud, BuiltInAdapterPacks.githubCLI, BuiltInAdapterPacks.terraform].map {
            AdapterSummary(payload: $0, adapterHash: AdapterCanonicalizer.hash($0), installedAt: Date(timeIntervalSince1970: 0))
        }
        let installed = try AdapterRegistryStore(url: adapterRegistryURL).loadDocument().entries.map {
            AdapterSummary(payload: $0.payload, adapterHash: $0.adapterHash, installedAt: $0.installedAt, revokedAt: $0.revokedAt)
        }
        return builtIns + installed
    }

    private func securityHealth(registrations: [CLIRegistrationSummary]) -> SecurityHealthSummary {
        var attention: [String] = []
        if registrations.contains(where: { $0.trustStatus != "trusted" }) {
            attention.append("One or more CLI registrations are not sealed to a target identity.")
        }
        let report = MacOSCompatibility.runtimeReport()
        if !report.runtimeOK {
            attention.append("This macOS runtime is below the configured minimum.")
        }
        let status: ManagementHealthStatus = attention.isEmpty ? .ok : .attention
        return SecurityHealthSummary(
            status: status,
            attentionItems: attention,
            localSelfBuildReady: ReleaseGateRunner().staticReport().canRunLocal,
            runtimeMajor: report.runtimeMajor,
            requiredSDKMajor: report.requiredSDKMajor
        )
    }

    private func assertRedacted<T: Codable>(_ value: T) throws -> T {
        let encoded = try AgenticFortressJSON.encodePretty(value)
        let redacted = Redactor().redact(encoded)
        guard encoded == redacted else {
            throw ManagementError.rawSecretInResponse
        }
        return value
    }
}
