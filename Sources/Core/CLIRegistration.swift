import Foundation

public struct CLIEnvironmentBinding: Codable, Equatable, Sendable {
    public var environmentName: String
    public var secretAlias: String

    public init(environmentName: String, secretAlias: String) {
        self.environmentName = environmentName
        self.secretAlias = secretAlias
    }
}

public struct CLIAppRegistration: Codable, Equatable, Sendable {
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

    public init(
        name: String,
        targetPath: String,
        targetResolvedPath: String? = nil,
        targetIdentity: String? = nil,
        targetCDHash: String? = nil,
        targetDesignatedRequirement: String? = nil,
        targetSigningIdentifier: String? = nil,
        targetTeamIdentifier: String? = nil,
        environmentBindings: [CLIEnvironmentBinding],
        registeredAt: Date
    ) {
        self.name = name
        self.targetPath = targetPath
        self.targetResolvedPath = targetResolvedPath
        self.targetIdentity = targetIdentity
        self.targetCDHash = targetCDHash
        self.targetDesignatedRequirement = targetDesignatedRequirement
        self.targetSigningIdentifier = targetSigningIdentifier
        self.targetTeamIdentifier = targetTeamIdentifier
        self.environmentBindings = environmentBindings
        self.registeredAt = registeredAt
    }
}

public struct CLIRegistrationDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var registrations: [String: CLIAppRegistration]

    public init(schemaVersion: Int = 1, registrations: [String: CLIAppRegistration] = [:]) {
        self.schemaVersion = schemaVersion
        self.registrations = registrations
    }
}

public enum CLIRegistrationError: Error, Equatable, CustomStringConvertible {
    case invalidCLIName(String)
    case invalidEnvironmentName(String)
    case missingEnvironmentValue(String)
    case targetNotExecutable(String)
    case targetIdentityChanged(name: String, expected: String, actual: String)
    case unsupportedSchema(Int)
    case registrationMissing(String)

    public var description: String {
        switch self {
        case .invalidCLIName(let name):
            "Invalid CLI name '\(name)'. Use a command name like 'hcloud' or pass a target path with --target."
        case .invalidEnvironmentName(let name):
            "Invalid environment variable name '\(name)'. Pass only the name, for example --env HCLOUD_TOKEN. Do not pass HCLOUD_TOKEN=value."
        case .missingEnvironmentValue(let name):
            "Missing secret value for environment variable '\(name)'. Use --secret-stdin, --secret-prompt, or --secrets-json-stdin."
        case .targetNotExecutable(let path):
            "Target is not executable: \(path)"
        case .targetIdentityChanged(let name, let expected, let actual):
            "Registered target identity changed for '\(name)'. Expected \(expected), got \(actual). Re-register the CLI after verifying the target binary."
        case .unsupportedSchema(let schema):
            "Unsupported CLI registry schema version: \(schema)"
        case .registrationMissing(let name):
            "No CLI registration found for '\(name)'."
        }
    }
}

public struct CLIRegistrationStore: Sendable {
    public var registryURL: URL

    public init(registryURL: URL) {
        self.registryURL = registryURL
    }

    public func load() throws -> CLIRegistrationDocument {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return CLIRegistrationDocument()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CLIRegistrationDocument.self, from: Data(contentsOf: registryURL))
        guard document.schemaVersion == 1 else {
            throw CLIRegistrationError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    public func save(_ document: CLIRegistrationDocument) throws {
        try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: registryURL.deletingLastPathComponent().path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: registryURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
    }
}

public struct CLIRegistrationService: Sendable {
    public var registryStore: CLIRegistrationStore
    public var secretStore: LocalEncryptedSecretStore

    public init(registryStore: CLIRegistrationStore, secretStore: LocalEncryptedSecretStore) {
        self.registryStore = registryStore
        self.secretStore = secretStore
    }

    public func register(
        name: String,
        targetPath: String,
        environmentValues: [String: SecretMaterial],
        now: Date = Date()
    ) throws -> CLIAppRegistration {
        try validateCLIName(name)
        try validateExecutable(targetPath)
        let target = try TargetAssessor().assess(path: targetPath)
        let signature = CodeSignatureInspector.assess(path: target.resolvedPath)
        guard !environmentValues.isEmpty else {
            throw CLIRegistrationError.missingEnvironmentValue("*")
        }

        let bindings = try environmentValues.keys.sorted().map { environmentName in
            try validateEnvironmentName(environmentName)
            let alias = Self.defaultAlias(cliName: name, environmentName: environmentName)
            guard let material = environmentValues[environmentName] else {
                throw CLIRegistrationError.missingEnvironmentValue(environmentName)
            }
            try secretStore.store(alias: SecretAlias(alias), material: material, label: "\(name) \(environmentName)", environment: "cli:\(name)")
            return CLIEnvironmentBinding(environmentName: environmentName, secretAlias: alias)
        }

        var document = try registryStore.load()
        let registration = CLIAppRegistration(
            name: name,
            targetPath: stableInvocationPath(targetPath),
            targetResolvedPath: target.resolvedPath,
            targetIdentity: target.identity,
            targetCDHash: signature.cdHash,
            targetDesignatedRequirement: signature.designatedRequirement,
            targetSigningIdentifier: signature.signingIdentifier,
            targetTeamIdentifier: signature.teamIdentifier,
            environmentBindings: bindings,
            registeredAt: now
        )
        document.registrations[name] = registration
        try registryStore.save(document)
        return registration
    }

    public func unregister(name: String, deleteSecrets: Bool = false) throws -> CLIAppRegistration {
        var document = try registryStore.load()
        guard let registration = document.registrations.removeValue(forKey: name) else {
            throw CLIRegistrationError.registrationMissing(name)
        }
        if deleteSecrets {
            for binding in registration.environmentBindings {
                try secretStore.delete(alias: SecretAlias(binding.secretAlias))
            }
        }
        try registryStore.save(document)
        return registration
    }

    public func registration(named name: String) throws -> CLIAppRegistration {
        let document = try registryStore.load()
        guard let registration = document.registrations[name] else {
            throw CLIRegistrationError.registrationMissing(name)
        }
        return registration
    }

    public func validateTargetIdentity(registration: CLIAppRegistration, assessedTarget: TargetAssessment) throws {
        if let requirement = registration.targetDesignatedRequirement {
            guard CodeSignatureInspector.satisfies(path: assessedTarget.resolvedPath, requirementText: requirement) else {
                throw CLIRegistrationError.targetIdentityChanged(name: registration.name, expected: requirement, actual: assessedTarget.identity)
            }
            return
        }
        guard let expectedIdentity = registration.targetIdentity else {
            return
        }
        guard expectedIdentity == assessedTarget.identity else {
            throw CLIRegistrationError.targetIdentityChanged(name: registration.name, expected: expectedIdentity, actual: assessedTarget.identity)
        }
    }

    public static func defaultAlias(cliName: String, environmentName: String) -> String {
        "cli.\(cliName).\(environmentName.lowercased())"
    }

    private func validateCLIName(_ name: String) throws {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !name.contains("/") else {
            throw CLIRegistrationError.invalidCLIName(name)
        }
    }

    private func validateEnvironmentName(_ name: String) throws {
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw CLIRegistrationError.invalidEnvironmentName(name)
        }
    }

    private func validateExecutable(_ path: String) throws {
        let resolved = (path as NSString).resolvingSymlinksInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: resolved) else {
            throw CLIRegistrationError.targetNotExecutable(path)
        }
    }

    private func stableInvocationPath(_ path: String) -> String {
        if (path as NSString).isAbsolutePath {
            return path
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(path)
            .path
    }
}

public struct AgenticFortressStateLayout: Sendable {
    public var stateDirectory: URL

    public init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
    }

    public var registryURL: URL {
        stateDirectory.appendingPathComponent("cli-registry.json")
    }

    public var secretStoreURL: URL {
        stateDirectory.appendingPathComponent("secrets/secrets.json")
    }

    public var secretKeyURL: URL {
        stateDirectory.appendingPathComponent("secrets/secret-store.key")
    }

    public var registrationService: CLIRegistrationService {
        CLIRegistrationService(
            registryStore: CLIRegistrationStore(registryURL: registryURL),
            secretStore: LocalEncryptedSecretStore(storeURL: secretStoreURL, keyURL: secretKeyURL)
        )
    }

    public static func defaultStateDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgenticFortress/LocalState", isDirectory: true)
    }
}
