import AgenticSecretsBroker
import Darwin
import Foundation

@main
struct AgenticSecretsBrokerDaemon {
    private struct DeliveryAuthorizationRequest {
        var mode: DeliveryAuthorizationMode
        var shortTTL: TimeInterval
    }

    static func main() {
        do {
            try run()
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(64)
        }
    }

    private static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        if let command = args.first {
            args.removeFirst()
            switch command {
            case "serve":
                try serve(args)
            case "serve-once":
                try serveOnce(args)
                return
            case "local-secret-smoke":
                try runLocalSecretSmoke(args)
                return
            case "register-cli":
                try registerCLI(args)
                return
            case "run-cli":
                try runCLI(args)
                return
            case "trust-refresh-cli":
                try trustRefreshCLI(args)
                return
            case "unregister-cli":
                try unregisterCLI(args)
                return
            default:
                throw BrokerDaemonError.unknownCommand(command)
            }
        }

        let report = ReleaseGateRunner().staticReport()
        print(try AgenticSecretsJSON.encodePretty([
            "service": "agentic-secrets-brokerd",
            "mode": "local-self-build",
            "can_run_local": String(report.canRunLocal),
            "can_distribute_binary": String(report.canDistributeBinary),
            "note": "Default production track is self-build with local ad-hoc signing; Developer ID distribution is optional future maintainer work."
        ]))
    }

    private static func registerCLI(_ args: [String]) throws {
        let name = try requiredValue(after: "--name", in: args)
        let target = try requiredValue(after: "--target", in: args)
        let environmentNames = values(after: "--env", in: args)
        let layout = LocalInstallLayout(stateDirectory: stateDirectory(from: args))
        let values: [String: SecretMaterial]
        if args.contains("--secrets-json-stdin") {
            values = try readSecretJSONFromStdin(allowedEnvironmentNames: environmentNames)
        } else if args.contains("--secret-stdin") {
            guard environmentNames.count == 1, let environmentName = environmentNames.first else {
                throw BrokerDaemonError.invalidArguments("--secret-stdin requires exactly one --env")
            }
            values = [environmentName: try readSingleSecretFromStdin()]
        } else if args.contains("--secret-prompt") {
            guard environmentNames.count == 1, let environmentName = environmentNames.first else {
                throw BrokerDaemonError.invalidArguments("--secret-prompt requires exactly one --env")
            }
            values = [environmentName: try readSingleSecretFromPrompt(label: "\(name) \(environmentName)")]
        } else {
            throw BrokerDaemonError.invalidArguments("use --secret-stdin, --secrets-json-stdin, or --secret-prompt")
        }
        let registration = try layout.registrationService.register(name: name, targetPath: target, environmentValues: values)
        print(try AgenticSecretsJSON.encodePretty(CLIRegistrationCommandResponse(
            status: "registered",
            name: registration.name,
            targetPath: registration.targetPath,
            environments: registration.environmentBindings.map(\.environmentName),
            registry: layout.registryURL.path,
            secretStore: "local-encrypted-file",
            nextStep: "Run with: agentic-secrets cli run \(registration.name) -- <arguments>. Do not create a native CLI context containing this token."
        )))
    }

    private static func runCLI(_ args: [String]) throws {
        let controlArguments = argumentsBeforeRunSeparator(in: args)
        let name = try requiredValue(after: "--name", in: controlArguments)
        let quiet = controlArguments.contains("--quiet")
        let authorization = try cliAuthorization(from: controlArguments)
        let targetArguments = argumentsAfterRunSeparator(in: args)
        let layout = LocalInstallLayout(stateDirectory: stateDirectory(from: controlArguments))
        let registration = try layout.registrationService.registration(named: name)
        let executableName = URL(fileURLWithPath: registration.targetPath).lastPathComponent
        let commandPolicy = (try? ConfigurationLoader.load(path: layout.configURL.path).commandPolicy) ?? .default
        let command = CommandClassifier(commandPolicy: commandPolicy).classify(executableName: executableName, arguments: targetArguments)
        let target = try TargetAssessor().assess(path: registration.targetPath)
        try layout.registrationService.validateTargetIdentity(registration: registration, assessedTarget: target)
        let environmentNames = registration.environmentBindings.map(\.environmentName)
        _ = try EnvironmentScrubber().scrub(
            parent: ProcessInfo.processInfo.environment,
            injectedValues: Dictionary(uniqueKeysWithValues: environmentNames.map { ($0, "") })
        )

        var injectedValues: [String: String] = [:]
        let deliveryGrants = DeliveryGrantStore(url: layout.deliveryGrantsURL, keyURL: layout.deliveryGrantKeyURL)
        let persistentAllows = RememberedApprovalStore(
            url: layout.rememberedApprovalsURL,
            integrityProtector: layout.cliPersistentAllowIntegrityProtector
        )
        for binding in registration.environmentBindings {
            let origin = ProcessOriginHint.current()
            let intent = DeliveryRequest(
                flow: .cliEnv,
                secretAlias: binding.secretAlias,
                delivery: .env,
                environmentName: binding.environmentName,
                workspace: FileManager.default.currentDirectoryPath,
                originHint: origin.displayName,
                provenanceConfidence: origin.provenanceConfidence
            )
            let manifest = DeliveryDecisionManifestFactory().make(command: command, intent: intent, target: target)
            let approvalOption = effectiveApprovalOption(selectedMode: authorization.mode, manifest: manifest)
            try authorizeCLIRun(command: command, intent: intent, target: target, approval: approvalOption)
            let unlockScope = DeliveryGrantScope(manifest: manifest)
            let persistentScope = RememberedApprovalScope(manifest: manifest)
            let cachedPersistentGrant = authorization.mode.isPersistent && RememberedApprovalPolicy.allowsPersistentGrant(manifest: manifest)
                ? try persistentAllows.validGrant(scope: persistentScope)
                : nil
            let cachedGrant = authorization.mode == .short && DeliveryGrantPolicy.allowsReuse(scope: unlockScope)
                ? try deliveryGrants.validGrant(scope: unlockScope)
                : nil
            let session = ApprovalSession(
                id: "run_" + shortDigest(UUID().uuidString, length: 16),
                manifestDigest: manifest.digest,
                actionClass: manifest.actionClass,
                secretAlias: SecretAlias(binding.secretAlias),
                approvalOption: approvalOption,
                policyEpoch: 1,
                expiresAt: Date().addingTimeInterval(60),
                authenticationReason: LocalAuthenticationGate.reason(for: manifest)
            )
            if cachedPersistentGrant == nil, cachedGrant == nil, !quiet {
                fputs("AgenticSecrets: requesting local authentication for \(registration.name) \(binding.environmentName).\n", stderr)
            } else if let cachedPersistentGrant, !quiet {
                let detail = cachedPersistentGrant.expiresAt.map { "\(max(0, Int($0.timeIntervalSinceNow.rounded(.down))))s remaining" } ?? "always allow"
                fputs("AgenticSecrets: using persistent authorization for \(registration.name) \(binding.environmentName) (\(detail)).\n", stderr)
            } else if let cachedGrant, !quiet {
                let seconds = max(0, Int(cachedGrant.expiresAt.timeIntervalSinceNow.rounded(.down)))
                fputs("AgenticSecrets: using cached local authentication for \(registration.name) \(binding.environmentName) (\(seconds)s remaining).\n", stderr)
            }
            let material = try layout.registrationService.secretStore.resolve(
                alias: SecretAlias(binding.secretAlias),
                approvedFor: session,
                localAuthentication: cachedPersistentGrant == nil && cachedGrant == nil ? .required : .alreadySatisfied
            )
            if cachedPersistentGrant == nil, cachedGrant == nil {
                switch authorization.mode {
                case .always, .remember24h:
                    if RememberedApprovalPolicy.allowsPersistentGrant(manifest: manifest) {
                        try persistentAllows.grant(scope: persistentScope, mode: authorization.mode)
                    }
                case .short where DeliveryGrantPolicy.allowsReuse(scope: unlockScope):
                    try deliveryGrants.grant(scope: unlockScope, ttl: authorization.shortTTL)
                case .once, .short:
                    break
                }
            }
            material.withUTF8String { value in
                injectedValues[binding.environmentName] = value
            }
        }

        let environment = try EnvironmentScrubber().scrub(parent: ProcessInfo.processInfo.environment, injectedValues: injectedValues)
        if !quiet {
            let envNames = registration.environmentBindings.map(\.environmentName).sorted().joined(separator: ",")
            fputs("AgenticSecrets: running \(registration.name) -> \(target.resolvedPath) with env [\(envNames)] (secret values redacted).\n", stderr)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: target.resolvedPath)
        process.arguments = targetArguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        switch process.terminationReason {
        case .exit:
            exit(process.terminationStatus)
        case .uncaughtSignal:
            exit(128 + process.terminationStatus)
        @unknown default:
            exit(70)
        }
    }

    private static func effectiveApprovalOption(selectedMode: DeliveryAuthorizationMode, manifest: DeliveryDecisionManifest) -> ApprovalOption {
        let selected = ApprovalOption(authorizationMode: selectedMode)
        return manifest.approvalOptions.contains(selected) ? selected : .once
    }

    private static func authorizeCLIRun(command: NormalizedCommand, intent: DeliveryRequest, target: TargetAssessment, approval: ApprovalOption) throws {
        do {
            let decision = try PolicyEngine().authorize(command: command, intent: intent, target: target, approval: approval, state: PolicyState())
            if case .deny(let reason) = decision {
                throw BrokerDaemonError.policyDenied(reason)
            }
        } catch let error as PolicyError {
            throw BrokerDaemonError.policyDenied(policyErrorDescription(error))
        }
    }

    private static func unregisterCLI(_ args: [String]) throws {
        let name = try requiredValue(after: "--name", in: args)
        let deleteSecrets = args.contains("--delete-secrets")
        let layout = LocalInstallLayout(stateDirectory: stateDirectory(from: args))
        let registration = try layout.registrationService.unregister(name: name, deleteSecrets: deleteSecrets)
        print(try AgenticSecretsJSON.encodePretty(CLIUnregistrationCommandResponse(
            status: "unregistered",
            name: registration.name,
            deletedSecrets: deleteSecrets,
            environments: registration.environmentBindings.map(\.environmentName)
        )))
    }

    private static func trustRefreshCLI(_ args: [String]) throws {
        let name = try requiredValue(after: "--name", in: args)
        let layout = LocalInstallLayout(stateDirectory: stateDirectory(from: args))
        let registration = try layout.registrationService.refreshTargetTrust(name: name) { request in
            fputs("AgenticSecrets: requesting local authentication to update trusted target identity for \(request.name).\n", stderr)
            fputs("AgenticSecrets: current identity \(request.currentIdentity ?? "missing"), proposed identity \(request.proposedIdentity).\n", stderr)
            try LocalAuthenticationPolicyGate().authorize(
                reason: "Agentic Secrets wants to update trusted target identity for \(request.name)."
            )
        }
        print(try AgenticSecretsJSON.encodePretty(CLITrustRefreshCommandResponse(
            status: "trust-refreshed",
            name: registration.name,
            targetPath: registration.targetPath,
            targetResolvedPath: registration.targetResolvedPath,
            targetIdentity: registration.targetIdentity,
            targetCDHash: registration.targetCDHash,
            targetDesignatedRequirement: registration.targetDesignatedRequirement,
            targetSigningIdentifier: registration.targetSigningIdentifier,
            targetTeamIdentifier: registration.targetTeamIdentifier
        )))
    }

    private static func serveOnce(_ args: [String]) throws {
        try makeIPCServer(args).serveOnce()
    }

    private static func serve(_ args: [String]) throws -> Never {
        try makeIPCServer(args).serveForever()
    }

    private static func makeIPCServer(_ args: [String]) throws -> UnixDomainSocketIPCServer {
        let socket = try requiredValue(after: "--socket", in: args)
        let manifestPath = try requiredValue(after: "--manifest", in: args)
        let manifest = try InstallManifestStore.load(path: manifestPath)
        let handler = BrokerIPCHandler(
            authorizer: BrokerIPCAuthorizer(installManifest: manifest),
            management: ControlPlane(
                stateDirectory: stateDirectory(from: args),
                installPrefix: URL(fileURLWithPath: manifest.prefix, isDirectory: true),
                shimRequirement: manifest.requirement(for: "agentic-secrets-shim")
            )
        )
        return UnixDomainSocketIPCServer(socketPath: socket, handler: handler)
    }

    private static func runLocalSecretSmoke(_ args: [String]) throws {
        let service = value(after: "--service", in: args) ?? "com.agenticsecrets.interactive-smoke"
        let alias = SecretAlias(value(after: "--alias", in: args) ?? "agentic-secrets.interactive-smoke")
        let smokeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(service)-\(UUID().uuidString)", isDirectory: true)
        let store = LocalEncryptedSecretStore(
            storeURL: smokeRoot.appendingPathComponent("secrets.json"),
            keyURL: smokeRoot.appendingPathComponent("secret-store.key")
        )
        let material = SecretMaterial(utf8: "generated-\(UUID().uuidString)")
        try store.store(alias: alias, material: material, label: "Agentic Secrets interactive smoke")
        defer { try? FileManager.default.removeItem(at: smokeRoot) }

        let command = CommandClassifier().classify(executableName: "agentic-secrets-brokerd", arguments: ["local-secret-smoke"])
        let target = TargetAssessor().synthetic(path: CommandLine.arguments.first ?? "agentic-secrets-brokerd", identity: "sha256:local-secret-smoke")
        let manifest = DeliveryDecisionManifestFactory().make(
            command: command,
            intent: DeliveryRequest(
                flow: .cliEnv,
                secretAlias: alias.rawValue,
                delivery: .env,
                environmentName: "AGENTIC_SECRETS_SMOKE_SECRET",
                workspace: FileManager.default.currentDirectoryPath,
                originHint: ProcessOriginHint.current().displayName,
                provenanceConfidence: ProcessOriginHint.current().provenanceConfidence
            ),
            target: target
        )
        let session = ApprovalSessionStore().create(manifest: manifest, policyEpoch: 1, ttl: 30)
        _ = try store.resolve(alias: alias, approvedFor: session)
        print(try AgenticSecretsJSON.encodePretty([
            "status": "ok",
            "secret": "resolved-redacted",
            "store": "local-encrypted-file",
            "manifestDigest": manifest.digest,
            "promptReasonContainsTarget": String(session.authenticationReason.contains(manifest.target.display)),
            "promptReasonContainsWorkspace": String(session.authenticationReason.contains(manifest.workspace.display)),
            "promptReasonContainsDelivery": String(session.authenticationReason.contains(manifest.secret.delivery.rawValue))
        ]))
    }

    private static func requiredValue(after flag: String, in args: [String]) throws -> String {
        guard let value = value(after: flag, in: args) else {
            throw BrokerDaemonError.missingArgument(flag)
        }
        return value
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else { return nil }
        return args[valueIndex]
    }

    private static func values(after flag: String, in args: [String]) -> [String] {
        args.indices.compactMap { index in
            guard args[index] == flag else { return nil }
            let valueIndex = args.index(after: index)
            guard valueIndex < args.endIndex else { return nil }
            return args[valueIndex]
        }
    }

    private static func stateDirectory(from args: [String]) -> URL {
        if let stateDir = value(after: "--state-dir", in: args) {
            return URL(fileURLWithPath: stateDir, isDirectory: true)
        }
        return LocalInstallLayout.defaultStateDirectory()
    }

    private static func cliAuthorization(from args: [String]) throws -> DeliveryAuthorizationRequest {
        if let rawMode = value(after: "--authorization-mode", in: args)
            ?? ProcessInfo.processInfo.environment["AGENTIC_SECRETS_CLI_AUTHORIZATION_MODE"] {
            guard let mode = DeliveryAuthorizationMode(rawValue: rawMode) else {
                throw BrokerDaemonError.invalidArguments("--authorization-mode must be one of: once, short, remember-24h, always")
            }
            return DeliveryAuthorizationRequest(mode: mode, shortTTL: try cliUnlockTTL(from: args, defaultingTo: DeliveryGrantPolicy.defaultTTL))
        }
        if value(after: "--delivery-grant-ttl-seconds", in: args) != nil || ProcessInfo.processInfo.environment["AGENTIC_SECRETS_CLI_UNLOCK_TTL_SECONDS"] != nil {
            let ttl = try cliUnlockTTL(from: args, defaultingTo: DeliveryGrantPolicy.defaultTTL)
            return DeliveryAuthorizationRequest(mode: ttl == 0 ? .once : .short, shortTTL: ttl)
        }
        return DeliveryAuthorizationRequest(mode: RememberedApprovalPolicy.defaultMode, shortTTL: DeliveryGrantPolicy.defaultTTL)
    }

    private static func cliUnlockTTL(from args: [String], defaultingTo defaultTTL: TimeInterval) throws -> TimeInterval {
        let raw = value(after: "--delivery-grant-ttl-seconds", in: args)
            ?? ProcessInfo.processInfo.environment["AGENTIC_SECRETS_CLI_UNLOCK_TTL_SECONDS"]
            ?? String(Int(defaultTTL))
        guard let seconds = TimeInterval(raw), seconds >= 0, seconds <= DeliveryGrantPolicy.maxTTL else {
            throw BrokerDaemonError.invalidArguments("--delivery-grant-ttl-seconds must be between 0 and \(Int(DeliveryGrantPolicy.maxTTL))")
        }
        return seconds
    }

    private static func argumentsAfterRunSeparator(in args: [String]) -> [String] {
        guard let separator = args.firstIndex(of: "--") else {
            return []
        }
        return Array(args[args.index(after: separator)...])
    }

    private static func argumentsBeforeRunSeparator(in args: [String]) -> [String] {
        guard let separator = args.firstIndex(of: "--") else {
            return args
        }
        return Array(args[..<separator])
    }

    private static func policyErrorDescription(_ error: PolicyError) -> String {
        switch error {
        case .locked:
            "Policy is locked."
        case .genericEnvDenied:
            "Generic runners are not allowed to receive raw environment secrets."
        case .destructiveRememberDenied:
            "High-risk or destructive commands are denied for cli run."
        case .forbiddenCommand(let term):
            "Command matched forbidden term '\(term)'."
        case .unknownDenied:
            "Unknown-risk commands are denied for cli run."
        }
    }

    private static func readSingleSecretFromStdin() throws -> SecretMaterial {
        guard isatty(STDIN_FILENO) != 1 else {
            throw BrokerDaemonError.invalidArguments("--secret-stdin reads from a pipe and does not prompt. Use --secret-prompt for interactive entry, or pipe a value into stdin.")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let trimmed = trimTrailingNewlines(data)
        guard !trimmed.isEmpty else {
            throw BrokerDaemonError.invalidArguments("empty secret stdin")
        }
        return SecretMaterial(bytes: trimmed)
    }

    private static func readSecretJSONFromStdin(allowedEnvironmentNames: [String]) throws -> [String: SecretMaterial] {
        guard isatty(STDIN_FILENO) != 1 else {
            throw BrokerDaemonError.invalidArguments("--secrets-json-stdin reads JSON from a pipe and does not prompt. Pipe JSON into stdin or use --secret-prompt for one secret.")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        let allowed = Set(allowedEnvironmentNames)
        guard !raw.isEmpty else {
            throw BrokerDaemonError.invalidArguments("empty secrets JSON")
        }
        if !allowed.isEmpty && !Set(raw.keys).isSubset(of: allowed) {
            throw BrokerDaemonError.invalidArguments("secrets JSON contains env names not listed with --env")
        }
        return raw.mapValues { SecretMaterial(utf8: $0) }
    }

    private static func readSingleSecretFromPrompt(label: String) throws -> SecretMaterial {
        guard isatty(STDIN_FILENO) == 1 else {
            throw BrokerDaemonError.invalidArguments("--secret-prompt requires a TTY")
        }
        fputs("Enter secret for \(label): ", stderr)
        var oldTermios = termios()
        guard tcgetattr(STDIN_FILENO, &oldTermios) == 0 else {
            throw BrokerDaemonError.invalidArguments("failed to read terminal settings")
        }
        var newTermios = oldTermios
        newTermios.c_lflag &= ~UInt(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &newTermios) == 0 else {
            throw BrokerDaemonError.invalidArguments("failed to disable terminal echo")
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &oldTermios)
            fputs("\n", stderr)
        }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw BrokerDaemonError.invalidArguments("empty secret")
        }
        return SecretMaterial(utf8: line)
    }

    private static func trimTrailingNewlines(_ data: Data) -> Data {
        var bytes = Array(data)
        while let last = bytes.last, last == 10 || last == 13 {
            bytes.removeLast()
        }
        return Data(bytes)
    }
}

enum BrokerDaemonError: Error, CustomStringConvertible {
    case missingArgument(String)
    case unknownCommand(String)
    case invalidArguments(String)
    case policyDenied(String)

    var description: String {
        switch self {
        case .missingArgument(let argument):
            "Missing argument: \(argument)"
        case .unknownCommand(let command):
            "Unknown broker daemon command: \(command)"
        case .invalidArguments(let reason):
            "Invalid arguments: \(reason)"
        case .policyDenied(let reason):
            "Policy denied cli run: \(reason)"
        }
    }
}

private struct CLIRegistrationCommandResponse: Codable {
    var status: String
    var name: String
    var targetPath: String
    var environments: [String]
    var registry: String
    var secretStore: String
    var nextStep: String
}

private struct CLIUnregistrationCommandResponse: Codable {
    var status: String
    var name: String
    var deletedSecrets: Bool
    var environments: [String]
}

private struct CLITrustRefreshCommandResponse: Codable {
    var status: String
    var name: String
    var targetPath: String
    var targetResolvedPath: String?
    var targetIdentity: String?
    var targetCDHash: String?
    var targetDesignatedRequirement: String?
    var targetSigningIdentifier: String?
    var targetTeamIdentifier: String?
}
