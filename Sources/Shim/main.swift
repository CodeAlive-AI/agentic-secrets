import AgenticFortressCore
import Darwin
import Foundation

@main
struct AgenticFortressShim {
    static func main() {
        do {
            try run()
        } catch {
            fputs("AgenticFortress shim error: \(error)\n", stderr)
            exit(64)
        }
    }

    private static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--ipc-health" {
            try runIPCHealth(Array(args.dropFirst()))
            return
        }
        let invokedName = URL(fileURLWithPath: CommandLine.arguments.first ?? "agentic-fortress-shim").lastPathComponent
        guard invokedName != "agentic-fortress-shim" else {
            throw ShimCLIError.missingArgument("invoke this binary through a registered CLI symlink, for example hcloud")
        }
        if CLIShimPolicy.isGlobalPassThrough(arguments: args) {
            try runGlobalPassThrough(name: invokedName, arguments: args)
        }
        try runThroughFortress(name: invokedName, arguments: args)
    }

    private static func runGlobalPassThrough(name: String, arguments: [String]) throws -> Never {
        let layout = AgenticFortressStateLayout(stateDirectory: defaultStateDirectory())
        let document = try CLIRegistrationStore(registryURL: layout.registryURL, integrityProtector: nil).load()
        guard let registration = document.registrations[name] else {
            throw CLIRegistrationError.registrationMissing(name)
        }
        let target = try TargetAssessor().assess(path: registration.targetPath)
        let environment = try EnvironmentScrubber().scrub(parent: ProcessInfo.processInfo.environment, injectedValues: [:])
        fputs("AgenticFortress: pass-through \(name) help/version without secret delivery.\n", stderr)
        try runProcess(executable: target.resolvedPath, arguments: arguments, environment: environment)
    }

    private static func runThroughFortress(name: String, arguments: [String]) throws -> Never {
        try runProcess(executable: try cliPath(), arguments: ["cli", "run", name, "--"] + arguments, environment: ProcessInfo.processInfo.environment)
    }

    private static func runProcess(executable: String, arguments: [String], environment: [String: String]) throws -> Never {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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

    private static func runIPCHealth(_ args: [String]) throws {
        let socket = try requiredValue(after: "--socket", in: args)
        _ = try requiredValue(after: "--manifest", in: args)
        let version = value(after: "--version", in: args) ?? "0.1.0"
        let path = CommandLine.arguments.first ?? "agentic-fortress-shim"
        let peer = try SelfBuildPeerValidator.identity(helperName: "agentic-fortress-shim", path: path, version: version)
        let request = CoreIPCRequest(requestID: "req_" + shortDigest(UUID().uuidString, length: 12), operation: .health, peer: peer)
        let response = try UnixDomainSocketIPCClient(socketPath: socket).send(request)
        print(try AgenticFortressJSON.encodePretty(response))
    }

    private static func requiredValue(after flag: String, in args: [String]) throws -> String {
        guard let value = value(after: flag, in: args) else {
            throw ShimCLIError.missingArgument(flag)
        }
        return value
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else { return nil }
        return args[valueIndex]
    }

    private static func cliPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_FORTRESS_CLI_BINARY"], !override.isEmpty {
            return override
        }
        for candidate in executableCandidateURLs().flatMap({ executable in
            [
                executable.deletingLastPathComponent().appendingPathComponent("agentic-fortress"),
                executable.deletingLastPathComponent().appendingPathComponent("AgenticFortress")
            ]
        }) where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        throw ShimCLIError.missingArgument("agentic-fortress sibling binary or AGENTIC_FORTRESS_CLI_BINARY")
    }

    private static func defaultStateDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENTIC_FORTRESS_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        for invoked in executableCandidateURLs().map({ $0.resolvingSymlinksInPath() }) {
            let components = invoked.pathComponents
            if let applicationsIndex = components.lastIndex(of: "Applications"), applicationsIndex > 0 {
                let prefix = URL(fileURLWithPath: "/" + components[1..<applicationsIndex].joined(separator: "/"), isDirectory: true)
                return prefix.appendingPathComponent("var/agentic-fortress", isDirectory: true)
            }
        }
        return AgenticFortressStateLayout.defaultStateDirectory()
    }

    private static func executableCandidateURLs() -> [URL] {
        var candidates: [URL] = []
        if let bundleExecutable = Bundle.main.executableURL {
            candidates.append(bundleExecutable)
        }
        let argv0 = CommandLine.arguments[0]
        if argv0.contains("/") {
            candidates.append(URL(fileURLWithPath: argv0))
        } else if let pathExecutable = findExecutableOnPATH(argv0) {
            candidates.append(URL(fileURLWithPath: pathExecutable))
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }

    private static func findExecutableOnPATH(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return nil
        }
        return output
    }
}

enum ShimCLIError: Error, CustomStringConvertible {
    case missingArgument(String)

    var description: String {
        switch self {
        case .missingArgument(let argument):
            "Missing argument: \(argument)"
        }
    }
}
