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
    public var environmentBindings: [CLIEnvironmentBinding]
    public var registeredAt: Date

    public init(name: String, targetPath: String, environmentBindings: [CLIEnvironmentBinding], registeredAt: Date) {
        self.name = name
        self.targetPath = targetPath
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
    case unsupportedSchema(Int)
    case registrationMissing(String)

    public var description: String {
        switch self {
        case .invalidCLIName(let name):
            "invalidCLIName(\(name))"
        case .invalidEnvironmentName(let name):
            "invalidEnvironmentName(\(name))"
        case .missingEnvironmentValue(let name):
            "missingEnvironmentValue(\(name))"
        case .targetNotExecutable(let path):
            "targetNotExecutable(\(path))"
        case .unsupportedSchema(let schema):
            "unsupportedSchema(\(schema))"
        case .registrationMissing(let name):
            "registrationMissing(\(name))"
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
            targetPath: (targetPath as NSString).resolvingSymlinksInPath,
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
