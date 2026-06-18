import Foundation

public enum ControlPlaneHealthStatus: String, Codable, Equatable, Sendable {
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
    public var environmentBindings: [EnvironmentSecretBinding]
    public var registeredAt: Date
    public var trustStatus: String
    public var shimStatus: String

    public init(registration: CommandLineToolRegistration, shimStatus: String = "unknown") {
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

public struct APISessionProfileSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var upstreamOrigin: URL
    public var allowedPathPrefixes: [String]
    public var allowedMethods: [String]
    public var secretAlias: String
    public var tokenTTLSeconds: TimeInterval

    public init(profile: APISessionProfile) {
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

public struct BitwardenBindingSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var projectID: String
    public var secretIDDigest: String
    public var environment: String
    public var maxLeaseSeconds: TimeInterval
    public var requiresPerFetchApproval: Bool

    public init(binding: BitwardenSecretBinding, policy: BitwardenProviderLeasePolicy) {
        self.alias = binding.alias
        self.projectID = binding.projectID
        self.secretIDDigest = "sha256:" + shortDigest(binding.secretID, length: 16)
        self.environment = binding.environment
        self.maxLeaseSeconds = policy.maxLeaseSeconds
        self.requiresPerFetchApproval = policy.requiresPerFetchApproval
    }
}

public struct PolicyPackSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { policyPackID }
    public var policyPackID: String
    public var policyPackVersion: Int
    public var cliName: String
    public var publisher: String
    public var policyPackHash: String
    public var installedAt: Date?
    public var revokedAt: Date?
    public var ruleCount: Int

    public init(payload: CommandPolicyPackPayload, policyPackHash: String, installedAt: Date? = nil, revokedAt: Date? = nil) {
        self.policyPackID = payload.policyPackID
        self.policyPackVersion = payload.policyPackVersion
        self.cliName = payload.cliName
        self.publisher = payload.publisher
        self.policyPackHash = policyPackHash
        self.installedAt = installedAt
        self.revokedAt = revokedAt
        self.ruleCount = payload.rules.count
    }
}

public struct UnlockGrantSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { scopeDigest }
    public var scopeDigest: String
    public var mode: DeliveryAuthorizationMode
    public var subject: String?
    public var actionClass: String?
    public var risk: RiskLevel?
    public var originHint: String?
    public var provenanceConfidence: ProvenanceConfidence?
    public var grantedAt: Date
    public var expiresAt: Date

    public init(scopeDigest: String, mode: DeliveryAuthorizationMode = .short, scope: DeliveryGrantScope?, grantedAt: Date, expiresAt: Date) {
        self.scopeDigest = scopeDigest
        self.mode = mode
        self.subject = scope?.subject
        self.actionClass = scope?.actionClass
        self.risk = scope?.risk
        self.originHint = scope?.originHint
        self.provenanceConfidence = scope?.provenanceConfidence
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
    }

    public init(grant: RememberedApproval) {
        self.scopeDigest = grant.scopeDigest
        self.mode = grant.mode
        self.subject = grant.scope.subject
        self.actionClass = nil
        self.risk = nil
        self.originHint = grant.scope.originHint
        self.provenanceConfidence = grant.scope.provenanceConfidence
        self.grantedAt = grant.grantedAt
        self.expiresAt = grant.expiresAt ?? Date.distantFuture
    }
}

public struct AuditEventSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(time.timeIntervalSince1970)-\(decisionDigest)-\(outcome)" }
    public var event: String
    public var decision: String
    public var decisionDigest: String
    public var flow: DeliveryChannel
    public var subjectID: String
    public var secretID: String
    public var actionClass: String
    public var targetIdentity: String
    public var workspaceHash: String
    public var originHint: String
    public var provenanceConfidence: ProvenanceConfidence
    public var delivery: DeliveryMechanism
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
    public var status: ControlPlaneHealthStatus
    public var attentionItems: [String]
    public var localSelfBuildReady: Bool
    public var runtimeMajor: Int
    public var requiredSDKMajor: Int
    public var protocolVersion: Int

    public init(status: ControlPlaneHealthStatus, attentionItems: [String], localSelfBuildReady: Bool, runtimeMajor: Int, requiredSDKMajor: Int, protocolVersion: Int = BrokerIPC.protocolVersion) {
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

public struct ControlPlaneSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var stateDirectory: String
    public var configPath: String
    public var cliRegistrations: [CLIRegistrationSummary]
    public var secrets: [ManagedSecretSummary]
    public var apiSessionProfiles: [APISessionProfileSummary]
    public var mcpProfiles: [MCPProfileSummary]
    public var bitwardenBindings: [BitwardenBindingSummary]
    public var policyPacks: [PolicyPackSummary]
    public var deliveryGrants: [UnlockGrantSummary]
    public var auditEvents: [AuditEventSummary]
    public var securityHealth: SecurityHealthSummary
    public var commandPolicy: CommandPolicySummary

    public init(
        generatedAt: Date,
        stateDirectory: String,
        configPath: String,
        cliRegistrations: [CLIRegistrationSummary],
        secrets: [ManagedSecretSummary],
        apiSessionProfiles: [APISessionProfileSummary],
        mcpProfiles: [MCPProfileSummary],
        bitwardenBindings: [BitwardenBindingSummary],
        policyPacks: [PolicyPackSummary],
        deliveryGrants: [UnlockGrantSummary],
        auditEvents: [AuditEventSummary],
        securityHealth: SecurityHealthSummary,
        commandPolicy: CommandPolicySummary
    ) {
        self.generatedAt = generatedAt
        self.stateDirectory = stateDirectory
        self.configPath = configPath
        self.cliRegistrations = cliRegistrations
        self.secrets = secrets
        self.apiSessionProfiles = apiSessionProfiles
        self.mcpProfiles = mcpProfiles
        self.bitwardenBindings = bitwardenBindings
        self.policyPacks = policyPacks
        self.deliveryGrants = deliveryGrants
        self.auditEvents = auditEvents
        self.securityHealth = securityHealth
        self.commandPolicy = commandPolicy
    }
}

public struct ControlPlaneCommandLineToolRegistrationRequest: Codable, Equatable, Sendable {
    public var name: String
    public var targetPath: String
    public var environmentSecrets: [String: String]

    public init(name: String, targetPath: String, environmentSecrets: [String: String]) {
        self.name = name
        self.targetPath = targetPath
        self.environmentSecrets = environmentSecrets
    }
}

public struct ControlPlaneNameRequest: Codable, Equatable, Sendable {
    public var name: String
    public var deleteSecretMaterial: Bool

    public init(name: String, deleteSecretMaterial: Bool = false) {
        self.name = name
        self.deleteSecretMaterial = deleteSecretMaterial
    }
}

public struct ControlPlaneSecretReplacementRequest: Codable, Equatable, Sendable {
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

public struct ControlPlaneSecretDeletionRequest: Codable, Equatable, Sendable {
    public var alias: String
    public var deleteSecretMaterial: Bool

    public init(alias: String, deleteSecretMaterial: Bool) {
        self.alias = alias
        self.deleteSecretMaterial = deleteSecretMaterial
    }
}

public struct ControlPlaneAPISessionRequest: Codable, Equatable, Sendable {
    public var profileName: String
    public var bindPort: Int

    public init(profileName: String, bindPort: Int) {
        self.profileName = profileName
        self.bindPort = bindPort
    }
}

public struct ControlPlaneAPISessionResponse: Codable, Equatable, Sendable {
    public var session: APISession
    public var oneTimeToken: String

    public init(session: APISession, oneTimeToken: String) {
        self.session = session
        self.oneTimeToken = oneTimeToken
    }
}

public struct ControlPlaneCommandPolicyUpdateRequest: Codable, Equatable, Sendable {
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

public enum ControlPlaneError: Error, Equatable, CustomStringConvertible {
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

public struct ControlPlane: Sendable {
    public var stateDirectory: URL
    public var configURL: URL
    public var adapterRegistryURL: URL
    public var auditLog: AuditLog
    public var witness: any DeliveryWitness

    public init(
        stateDirectory: URL = LocalInstallLayout.defaultStateDirectory(),
        configURL: URL? = nil,
        adapterRegistryURL: URL? = nil,
        auditLog: AuditLog = AuditLog(),
        witness: any DeliveryWitness = PermissiveDeliveryWitness()
    ) {
        self.stateDirectory = stateDirectory
        self.configURL = configURL ?? stateDirectory.appendingPathComponent("config/agentic-secrets.json")
        self.adapterRegistryURL = adapterRegistryURL ?? stateDirectory.appendingPathComponent("policyPacks/adapter-registry.json")
        self.auditLog = auditLog
        self.witness = witness
    }

    public func snapshot(now: Date = Date()) throws -> ControlPlaneSnapshot {
        let layout = LocalInstallLayout(stateDirectory: stateDirectory)
        let config = try loadConfig()
        let registry = try layout.registrationService.registryStore.load()
        let secrets = try loadSecretSummaries(layout: layout)
        let policyPacks = try adapterSummaries()
        let deliveryGrants = try loadUnlockGrantSummaries(layout: layout, now: now)
        let health = securityHealth(registrations: registry.registrations.values.map { CLIRegistrationSummary(registration: $0) })
        return try assertRedacted(ControlPlaneSnapshot(
            generatedAt: now,
            stateDirectory: stateDirectory.path,
            configPath: configURL.path,
            cliRegistrations: registry.registrations.values.map { CLIRegistrationSummary(registration: $0) }.sorted { $0.name < $1.name },
            secrets: secrets.sorted { $0.alias < $1.alias },
            apiSessionProfiles: config.apiSessionProfiles.map(APISessionProfileSummary.init).sorted { $0.name < $1.name },
            mcpProfiles: config.mcpProfiles.map(MCPProfileSummary.init).sorted { $0.name < $1.name },
            bitwardenBindings: config.bitwardenBindings.map {
                BitwardenBindingSummary(binding: $0, policy: BitwardenProviderLeasePolicy.policy(for: ProviderEnvironment(rawValue: $0.environment) ?? .dev))
            }.sorted { $0.alias < $1.alias },
            policyPacks: policyPacks.sorted { $0.cliName < $1.cliName },
            deliveryGrants: deliveryGrants.sorted { $0.expiresAt < $1.expiresAt },
            auditEvents: auditLog.snapshot().map(AuditEventSummary.init).sorted { $0.time > $1.time },
            securityHealth: health,
            commandPolicy: CommandPolicySummary(config: config.commandPolicy)
        ))
    }

    @discardableResult
    public func registerCLI(_ request: ControlPlaneCommandLineToolRegistrationRequest) throws -> CLIRegistrationSummary {
        let values = request.environmentSecrets.mapValues { SecretMaterial(utf8: $0) }
        let registration = try LocalInstallLayout(stateDirectory: stateDirectory).registrationService.register(
            name: request.name,
            targetPath: request.targetPath,
            environmentValues: values
        )
        return CLIRegistrationSummary(registration: registration)
    }

    @discardableResult
    public func unregisterCLI(_ request: ControlPlaneNameRequest) throws -> CLIRegistrationSummary {
        let registration = try LocalInstallLayout(stateDirectory: stateDirectory).registrationService.unregister(
            name: request.name,
            deleteSecrets: request.deleteSecretMaterial
        )
        return CLIRegistrationSummary(registration: registration)
    }

    @discardableResult
    public func refreshCLITrust(_ request: ControlPlaneNameRequest) throws -> CLIRegistrationSummary {
        let registration = try LocalInstallLayout(stateDirectory: stateDirectory).registrationService.refreshTargetTrust(name: request.name) { _ in }
        return CLIRegistrationSummary(registration: registration)
    }

    public func replaceSecret(_ request: ControlPlaneSecretReplacementRequest) throws -> ManagedSecretSummary {
        try witness.willReplaceSecret(alias: request.alias, environment: request.environment)
        let layout = LocalInstallLayout(stateDirectory: stateDirectory)
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

    public func deleteSecret(_ request: ControlPlaneSecretDeletionRequest) throws {
        guard request.deleteSecretMaterial else {
            throw ControlPlaneError.deleteSecretMaterialNotConfirmed
        }
        try LocalInstallLayout(stateDirectory: stateDirectory).registrationService.secretStore.delete(alias: SecretAlias(request.alias))
    }

    public func upsertAPISessionProfile(_ profile: APISessionProfile) throws -> APISessionProfileSummary {
        var config = try loadConfig()
        config.apiSessionProfiles.removeAll { $0.name == profile.name }
        config.apiSessionProfiles.append(profile)
        try saveConfig(config)
        return APISessionProfileSummary(profile: profile)
    }

    public func deleteAPISessionProfile(_ request: ControlPlaneNameRequest) throws {
        var config = try loadConfig()
        guard config.apiSessionProfiles.contains(where: { $0.name == request.name }) else {
            throw ControlPlaneError.missingProfile(request.name)
        }
        config.apiSessionProfiles.removeAll { $0.name == request.name }
        try saveConfig(config)
    }

    public func upsertMCPProfile(_ profile: MCPUpstreamProfile) throws -> MCPProfileSummary {
        var config = try loadConfig()
        config.mcpProfiles.removeAll { $0.name == profile.name }
        config.mcpProfiles.append(profile)
        try saveConfig(config)
        return MCPProfileSummary(profile: profile)
    }

    public func deleteMCPProfile(_ request: ControlPlaneNameRequest) throws {
        var config = try loadConfig()
        guard config.mcpProfiles.contains(where: { $0.name == request.name }) else {
            throw ControlPlaneError.missingProfile(request.name)
        }
        config.mcpProfiles.removeAll { $0.name == request.name }
        try saveConfig(config)
    }

    public func upsertBitwardenBinding(_ binding: BitwardenSecretBinding) throws -> BitwardenBindingSummary {
        var config = try loadConfig()
        config.bitwardenBindings.removeAll { $0.alias == binding.alias }
        config.bitwardenBindings.append(binding)
        try saveConfig(config)
        let environment = ProviderEnvironment(rawValue: binding.environment) ?? .dev
        return BitwardenBindingSummary(binding: binding, policy: BitwardenProviderLeasePolicy.policy(for: environment))
    }

    public func deleteBitwardenBinding(_ request: ControlPlaneNameRequest) throws {
        var config = try loadConfig()
        guard config.bitwardenBindings.contains(where: { $0.alias == request.name }) else {
            throw ControlPlaneError.missingBinding(request.name)
        }
        config.bitwardenBindings.removeAll { $0.alias == request.name }
        try saveConfig(config)
    }

    public func createAPISession(_ request: ControlPlaneAPISessionRequest) throws -> ControlPlaneAPISessionResponse {
        let config = try loadConfig()
        guard let profile = config.apiSessionProfiles.first(where: { $0.name == request.profileName }) else {
            throw ControlPlaneError.missingProfile(request.profileName)
        }
        let (session, token) = APISessionAuthorizer().createSession(profile: profile, bindPort: request.bindPort)
        return ControlPlaneAPISessionResponse(session: session, oneTimeToken: token)
    }

    public func createShimExecPlan(_ request: ShimExecPlanIPCRequest, provenanceConfidence: ProvenanceConfidence) throws -> ShimExecPlanIPCResponse {
        let commandName = URL(fileURLWithPath: request.invokedName).lastPathComponent
        let layout = LocalInstallLayout(stateDirectory: stateDirectory)
        let registration = try layout.registrationService.registration(named: commandName)
        let executableName = URL(fileURLWithPath: registration.targetPath).lastPathComponent
        let commandPolicy = (try? loadConfig().commandPolicy) ?? .default
        let command = CommandClassifier(commandPolicy: commandPolicy).classify(executableName: executableName, arguments: request.arguments)
        let target = try TargetAssessor().assess(path: registration.targetPath)
        try layout.registrationService.validateTargetIdentity(registration: registration, assessedTarget: target)
        let manifests = registration.environmentBindings.map { binding in
            DeliveryDecisionManifestFactory().make(
                command: command,
                intent: DeliveryRequest(
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

    public func installAdapter(_ payload: CommandPolicyPackPayload) throws -> PolicyPackSummary {
        try PolicyPackRegistryStore(url: adapterRegistryURL).install(payload: payload)
        return PolicyPackSummary(payload: payload, policyPackHash: AdapterCanonicalizer.hash(payload), installedAt: Date())
    }

    public func revokeAdapter(_ request: ControlPlaneNameRequest) throws {
        try PolicyPackRegistryStore(url: adapterRegistryURL).revoke(policyPackID: request.name)
    }

    public func updateCommandPolicy(_ request: ControlPlaneCommandPolicyUpdateRequest) throws -> CommandPolicySummary {
        var config = try loadConfig()
        config.commandPolicy = request.config
        try saveConfig(config)
        return CommandPolicySummary(config: config.commandPolicy)
    }

    public func clearDeliveryGrants() throws {
        let layout = LocalInstallLayout(stateDirectory: stateDirectory)
        try? FileManager.default.removeItem(at: layout.deliveryGrantsURL)
        try? FileManager.default.removeItem(at: layout.rememberedApprovalsURL)
    }

    public func exportRedactedAuditJSON() throws -> String {
        try auditLog.exportRedactedJSON()
    }

    private func loadConfig() throws -> AgenticSecretsConfiguration {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return AgenticSecretsConfiguration()
        }
        let config = try ConfigurationLoader.load(path: configURL.path)
        guard config.schemaVersion == 1 else {
            throw ControlPlaneError.unsupportedConfigSchema(config.schemaVersion)
        }
        return config
    }

    private func saveConfig(_ config: AgenticSecretsConfiguration) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigurationLoader.encode(config).write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func loadSecretSummaries(layout: LocalInstallLayout) throws -> [ManagedSecretSummary] {
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

    private func loadUnlockGrantSummaries(layout: LocalInstallLayout, now: Date) throws -> [UnlockGrantSummary] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let shortGrants: [UnlockGrantSummary]
        if FileManager.default.fileExists(atPath: layout.deliveryGrantsURL.path) {
            let document = try decoder.decode(DeliveryGrantDocument.self, from: Data(contentsOf: layout.deliveryGrantsURL))
            shortGrants = document.grants.values
                .filter { $0.expiresAt >= now }
                .map { UnlockGrantSummary(scopeDigest: $0.scopeDigest, scope: $0.scope, grantedAt: $0.grantedAt, expiresAt: $0.expiresAt) }
        } else {
            shortGrants = []
        }
        let persistentGrants: [UnlockGrantSummary]
        if FileManager.default.fileExists(atPath: layout.rememberedApprovalsURL.path) {
            let persistentDocument = try decoder.decode(RememberedApprovalDocument.self, from: Data(contentsOf: layout.rememberedApprovalsURL))
            persistentGrants = persistentDocument.grants.values
                .filter { $0.expiresAt.map { $0 >= now } ?? true }
                .map(UnlockGrantSummary.init)
        } else {
            persistentGrants = []
        }
        return shortGrants + persistentGrants
    }

    private func adapterSummaries() throws -> [PolicyPackSummary] {
        let builtIns = [BuiltInPolicyPacks.hcloud, BuiltInPolicyPacks.githubCLI, BuiltInPolicyPacks.terraform].map {
            PolicyPackSummary(payload: $0, policyPackHash: AdapterCanonicalizer.hash($0), installedAt: Date(timeIntervalSince1970: 0))
        }
        let installed = try PolicyPackRegistryStore(url: adapterRegistryURL).loadDocument().entries.map {
            PolicyPackSummary(payload: $0.payload, policyPackHash: $0.policyPackHash, installedAt: $0.installedAt, revokedAt: $0.revokedAt)
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
        let status: ControlPlaneHealthStatus = attention.isEmpty ? .ok : .attention
        return SecurityHealthSummary(
            status: status,
            attentionItems: attention,
            localSelfBuildReady: ReleaseGateRunner().staticReport().canRunLocal,
            runtimeMajor: report.runtimeMajor,
            requiredSDKMajor: report.requiredSDKMajor
        )
    }

    private func assertRedacted<T: Codable>(_ value: T) throws -> T {
        let encoded = try AgenticSecretsJSON.encodePretty(value)
        let redacted = Redactor().redact(encoded)
        guard encoded == redacted else {
            throw ControlPlaneError.rawSecretInResponse
        }
        return value
    }
}
