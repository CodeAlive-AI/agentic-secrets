import Foundation

public struct ShimRequest: Codable, Equatable, Sendable {
    public var invokedName: String
    public var arguments: [String]
    public var parentEnvironment: [String: String]
    public var workspace: String
    public var parentApp: String
    public var peerIdentity: String
    public var injectorIdentity: String

    public init(invokedName: String, arguments: [String], parentEnvironment: [String: String], workspace: String, parentApp: String, peerIdentity: String, injectorIdentity: String) {
        self.invokedName = invokedName
        self.arguments = arguments
        self.parentEnvironment = parentEnvironment
        self.workspace = workspace
        self.parentApp = parentApp
        self.peerIdentity = peerIdentity
        self.injectorIdentity = injectorIdentity
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
        targetAssessor: TargetAssessor = TargetAssessor(),
        now: Date = Date()
    ) throws -> ExecPlan {
        let commandName = URL(fileURLWithPath: request.invokedName).lastPathComponent
        guard let targetPolicy = targetPolicies.first(where: { $0.commandName == commandName }) else {
            throw ShimPlannerError.unknownTarget(commandName)
        }

        let command = classifier.classify(executableName: commandName, arguments: request.arguments)
        let target = try targetAssessor.assess(path: targetPolicy.targetPath)
        let intent = DeliveryIntent(flow: .cliEnv, secretAlias: targetPolicy.secretAlias, delivery: .env, environmentName: targetPolicy.environmentName, workspace: request.workspace, parentApp: request.parentApp)
        let manifest = DecisionManifestFactory().make(command: command, intent: intent, target: target)

        _ = try PolicyEngine().authorize(command: command, intent: intent, target: target, approval: manifest.approvalOptions.contains(.once) ? .once : .deny, state: policyState, now: now)
        let approval = try approvalSessions.validate(sessionID: approvalSessionID, manifest: manifest, policyEpoch: policyState.epoch, now: now)
        let secret = try secrets.resolve(alias: SecretAlias(targetPolicy.secretAlias), approvedFor: approval)
        let secretValue = secret.withUTF8String { $0 }
        let environment = try scrubber.scrub(parent: request.parentEnvironment, targetEnvironmentName: targetPolicy.environmentName, injectedValue: secretValue)
        let binding = InvocationBinding(
            peerIdentity: request.peerIdentity,
            injectorIdentity: request.injectorIdentity,
            targetIdentity: target.identity,
            actionClass: command.actionClass,
            workspace: request.workspace,
            parentApp: request.parentApp,
            policyEpoch: policyState.epoch,
            injectionMode: .env
        )
        let handle = try handles.create(binding: binding, ttl: 10, maxUses: 1, now: now)

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
