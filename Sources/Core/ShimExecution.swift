import Foundation

public struct ShimRequest: Codable, Equatable, Sendable {
    public var invokedName: String
    public var arguments: [String]
    public var parentEnvironment: [String: String]
    public var workspace: String
    public var originHint: String
    public var peerIdentity: String
    public var injectorIdentity: String

    public init(invokedName: String, arguments: [String], parentEnvironment: [String: String], workspace: String, originHint: String, peerIdentity: String, injectorIdentity: String) {
        self.invokedName = invokedName
        self.arguments = arguments
        self.parentEnvironment = parentEnvironment
        self.workspace = workspace
        self.originHint = originHint
        self.peerIdentity = peerIdentity
        self.injectorIdentity = injectorIdentity
    }
}

public struct ShimExecPlanIPCRequest: Codable, Equatable, Sendable {
    public var invokedName: String
    public var arguments: [String]
    public var workspace: String
    public var originHint: String
    public var parentEnvironmentKeys: [String]

    public init(
        invokedName: String,
        arguments: [String],
        workspace: String,
        originHint: String,
        parentEnvironmentKeys: [String]
    ) {
        self.invokedName = invokedName
        self.arguments = arguments
        self.workspace = workspace
        self.originHint = originHint
        self.parentEnvironmentKeys = parentEnvironmentKeys.sorted()
    }
}

public struct ShimExecPlanIPCResponse: Codable, Equatable, Sendable {
    public var commandName: String
    public var targetPath: String
    public var argv: [String]
    public var manifests: [DecisionManifest]
    public var provenanceConfidence: ProvenanceConfidence
    public var parentEnvironmentKeys: [String]

    public init(
        commandName: String,
        targetPath: String,
        argv: [String],
        manifests: [DecisionManifest],
        provenanceConfidence: ProvenanceConfidence,
        parentEnvironmentKeys: [String]
    ) {
        self.commandName = commandName
        self.targetPath = targetPath
        self.argv = argv
        self.manifests = manifests
        self.provenanceConfidence = provenanceConfidence
        self.parentEnvironmentKeys = parentEnvironmentKeys.sorted()
    }
}

public struct TargetPolicy: Codable, Equatable, Sendable {
    public var commandName: String
    public var targetPath: String
    public var secretAlias: String
    public var environmentName: String

    public init(commandName: String, targetPath: String, secretAlias: String, environmentName: String) {
        self.commandName = commandName
        self.targetPath = targetPath
        self.secretAlias = secretAlias
        self.environmentName = environmentName
    }
}

public struct ExecPlan: Equatable, Sendable {
    public var targetPath: String
    public var argv: [String]
    public var environment: [String: String]
    public var target: TargetAssessment
    public var invocationHandle: String
    public var manifest: DecisionManifest
}

public enum ShimPlannerError: Error, Equatable {
    case unknownTarget(String)
    case approvalDenied
    case secretResolutionFailed
}

public struct ShimExecutionPlanner: Sendable {
    private let classifier: CommandClassifier
    private let scrubber: EnvironmentScrubber

    public init(classifier: CommandClassifier = CommandClassifier(), scrubber: EnvironmentScrubber = EnvironmentScrubber()) {
        self.classifier = classifier
        self.scrubber = scrubber
    }

    public func plan(
        request: ShimRequest,
        targetPolicies: [TargetPolicy],
        policyState: PolicyState,
        approvalSessionID: String,
        approvalSessions: ApprovalSessionStore,
        secrets: LocalSecretStore,
        handles: InvocationHandleStore,
        audit: AuditLog? = nil,
        targetAssessor: TargetAssessor = TargetAssessor(),
        now: Date = Date()
    ) throws -> ExecPlan {
        let commandName = URL(fileURLWithPath: request.invokedName).lastPathComponent
        guard let targetPolicy = targetPolicies.first(where: { $0.commandName == commandName }) else {
            throw ShimPlannerError.unknownTarget(commandName)
        }

        let command = classifier.classify(executableName: commandName, arguments: request.arguments)
        let target = try targetAssessor.assess(path: targetPolicy.targetPath)
        let intent = DeliveryIntent(flow: .cliEnv, secretAlias: targetPolicy.secretAlias, delivery: .env, environmentName: targetPolicy.environmentName, workspace: request.workspace, originHint: request.originHint)
        let manifest = DecisionManifestFactory().make(command: command, intent: intent, target: target)

        let requestedApproval: ApprovalOption = manifest.approvalOptions.contains(.once) ? .once : .deny
        let decision: PolicyDecision
        do {
            decision = try PolicyEngine().authorize(command: command, intent: intent, target: target, approval: requestedApproval, state: policyState, now: now)
        } catch {
            try audit?.append(.delivery(manifest: manifest, decision: "deny", subjectID: request.peerIdentity, policyEpoch: policyState.epoch, approval: requestedApproval, outcome: "policy-error:\(error)", time: now))
            throw error
        }
        if case .deny(let reason) = decision {
            try audit?.append(.delivery(manifest: manifest, decision: "deny", subjectID: request.peerIdentity, policyEpoch: policyState.epoch, approval: requestedApproval, outcome: reason, time: now))
            throw ShimPlannerError.approvalDenied
        }

        let approval: ApprovalSession
        do {
            approval = try approvalSessions.validate(sessionID: approvalSessionID, manifest: manifest, policyEpoch: policyState.epoch, now: now)
        } catch {
            try audit?.append(.delivery(manifest: manifest, decision: "deny", subjectID: request.peerIdentity, policyEpoch: policyState.epoch, approval: requestedApproval, outcome: "approval-error:\(error)", time: now))
            throw error
        }
        let secret = try secrets.resolve(alias: SecretAlias(targetPolicy.secretAlias), approvedFor: approval)
        let secretValue = secret.withUTF8String { $0 }
        let environment = try scrubber.scrub(parent: request.parentEnvironment, targetEnvironmentName: targetPolicy.environmentName, injectedValue: secretValue)
        let binding = InvocationBinding(
            peerIdentity: request.peerIdentity,
            injectorIdentity: request.injectorIdentity,
            targetIdentity: target.identity,
            actionClass: command.actionClass,
            workspace: request.workspace,
            originHint: request.originHint,
            policyEpoch: policyState.epoch,
            injectionMode: .env
        )
        let handle = try handles.create(binding: binding, ttl: 10, maxUses: 1, now: now)
        try audit?.append(.delivery(manifest: manifest, decision: "allow", subjectID: request.peerIdentity, policyEpoch: policyState.epoch, approval: requestedApproval, outcome: "exec-plan-created", time: now, metadata: ["invocation_handle": "present-redacted"]))

        return ExecPlan(
            targetPath: target.resolvedPath,
            argv: [commandName] + request.arguments,
            environment: environment,
            target: target,
            invocationHandle: handle,
            manifest: manifest
        )
    }
}
