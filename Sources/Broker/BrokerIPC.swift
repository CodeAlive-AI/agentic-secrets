import Darwin
import Foundation

public enum BrokerIPC {
    public static let protocolVersion = 1
    public static let transport = "local-xpc-or-unix-domain-socket"
}

public enum BrokerIPCOperation: String, Codable, CaseIterable, Sendable {
    case health
    case loadControlPlaneSnapshot = "load-control-plane-snapshot"
    case registerCLI = "register-command-line-tool"
    case unregisterCLI = "unregister-command-line-tool"
    case refreshCLITrust = "refresh-command-line-tool-trust"
    case replaceSecret = "replace-secret"
    case deleteSecret = "delete-secret"
    case upsertAPISessionProfile = "upsert-api-session-profile"
    case deleteAPISessionProfile = "delete-api-session-profile"
    case upsertMCPProfile = "upsert-mcp-profile"
    case deleteMCPProfile = "delete-mcp-profile"
    case upsertBitwardenBinding = "upsert-bitwarden-binding"
    case deleteBitwardenBinding = "delete-bitwarden-binding"
    case createManagedAPISession = "create-managed-api-session"
    case installAdapter = "install-command-policy-pack"
    case revokeAdapter = "revoke-command-policy-pack"
    case updateCommandPolicy = "update-command-policy"
    case clearDeliveryGrants = "clear-delivery-grants"
    case exportRedactedAudit = "export-redacted-audit"
    case classifyCommand = "classify-command"
    case createDeliveryDecisionManifest = "create-delivery-decision-manifest"
    case createApprovalSession = "create-approval-session"
    case createShimExecPlan = "create-shim-exec-plan"
    case createAPISession = "create-api-session"
    case bridgeMCPMessage = "bridge-mcp-message"
}

public struct BrokerIPCRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var requestID: String
    public var operation: BrokerIPCOperation
    public var peer: SelfBuildPeerIdentity
    public var payload: Data

    public init(
        version: Int = BrokerIPC.protocolVersion,
        requestID: String,
        operation: BrokerIPCOperation,
        peer: SelfBuildPeerIdentity,
        payload: Data = Data()
    ) {
        self.version = version
        self.requestID = requestID
        self.operation = operation
        self.peer = peer
        self.payload = payload
    }
}

public struct BrokerIPCResponse: Codable, Equatable, Sendable {
    public var version: Int
    public var requestID: String
    public var ok: Bool
    public var payload: Data
    public var error: String?

    public init(
        version: Int = BrokerIPC.protocolVersion,
        requestID: String,
        ok: Bool,
        payload: Data = Data(),
        error: String? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.ok = ok
        self.payload = payload
        self.error = error
    }
}

public enum BrokerIPCError: Error, Equatable {
    case unsupportedVersion(Int)
    case unknownPeer(String)
    case unauthorizedPeer(String)
    case missingSocketPeerEvidence
    case malformedPayload
    case unsupportedOperation(BrokerIPCOperation)
    case socket(String)
}

public struct UnixSocketPeerEvidence: Codable, Equatable, Sendable {
    public var effectiveUserID: UInt32
    public var effectiveGroupID: UInt32
    public var processID: Int32?
    public var executablePath: String?
    public var auditTokenAvailable: Bool
    public var provenanceConfidence: ProvenanceConfidence

    public init(
        effectiveUserID: UInt32,
        effectiveGroupID: UInt32,
        processID: Int32? = nil,
        executablePath: String? = nil,
        auditTokenAvailable: Bool = false,
        provenanceConfidence: ProvenanceConfidence
    ) {
        self.effectiveUserID = effectiveUserID
        self.effectiveGroupID = effectiveGroupID
        self.processID = processID
        self.executablePath = executablePath
        self.auditTokenAvailable = auditTokenAvailable
        self.provenanceConfidence = provenanceConfidence
    }

    public func selfBuildIdentity(helperName: String, version: String) throws -> SelfBuildPeerIdentity {
        guard let executablePath, !executablePath.isEmpty else {
            throw BrokerIPCError.missingSocketPeerEvidence
        }
        return try SelfBuildPeerValidator.identity(helperName: helperName, path: executablePath, version: version)
    }
}

public struct BrokerIPCAuthorizer: Sendable {
    public var installManifest: InstallManifest

    public init(installManifest: InstallManifest) {
        self.installManifest = installManifest
    }

    public func authorize(_ request: BrokerIPCRequest) throws {
        try authorize(request, observedPeer: nil)
    }

    public func authorize(_ request: BrokerIPCRequest, observedPeer: SelfBuildPeerIdentity?) throws {
        guard request.version == BrokerIPC.protocolVersion else {
            throw BrokerIPCError.unsupportedVersion(request.version)
        }
        guard let requirement = installManifest.requirement(for: request.peer.helperName) else {
            throw BrokerIPCError.unknownPeer(request.peer.helperName)
        }
        do {
            try SelfBuildPeerValidator.validate(peer: observedPeer ?? request.peer, requirement: requirement)
        } catch {
            throw BrokerIPCError.unauthorizedPeer(String(describing: error))
        }
    }
}

public enum InstallManifestStore {
    public static func load(path: String) throws -> InstallManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InstallManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

public struct BrokerIPCHandler: Sendable {
    public var authorizer: BrokerIPCAuthorizer
    public var management: ControlPlane

    public init(authorizer: BrokerIPCAuthorizer, management: ControlPlane = ControlPlane()) {
        self.authorizer = authorizer
        self.management = management
    }

    public func handle(_ request: BrokerIPCRequest, observedPeer: SelfBuildPeerIdentity? = nil) throws -> BrokerIPCResponse {
        try authorizer.authorize(request, observedPeer: observedPeer)
        switch request.operation {
        case .health:
            let payload = try AgenticSecretsJSON.encodePretty([
                "service": "agentic-secrets-brokerd",
                "status": "ok",
                "protocolVersion": "\(BrokerIPC.protocolVersion)"
            ])
            return BrokerIPCResponse(requestID: request.requestID, ok: true, payload: Data(payload.utf8))
        case .loadControlPlaneSnapshot:
            return try encodeResponse(requestID: request.requestID, management.snapshot())
        case .registerCLI:
            return try encodeResponse(requestID: request.requestID, management.registerCLI(decodePayload(request.payload, as: ControlPlaneCommandLineToolRegistrationRequest.self)))
        case .unregisterCLI:
            return try encodeResponse(requestID: request.requestID, management.unregisterCLI(decodePayload(request.payload, as: ControlPlaneNameRequest.self)))
        case .refreshCLITrust:
            return try encodeResponse(requestID: request.requestID, management.refreshCLITrust(decodePayload(request.payload, as: ControlPlaneNameRequest.self)))
        case .replaceSecret:
            return try encodeResponse(requestID: request.requestID, management.replaceSecret(decodePayload(request.payload, as: ControlPlaneSecretReplacementRequest.self)))
        case .deleteSecret:
            try management.deleteSecret(decodePayload(request.payload, as: ControlPlaneSecretDeletionRequest.self))
            return BrokerIPCResponse(requestID: request.requestID, ok: true)
        case .upsertAPISessionProfile:
            return try encodeResponse(requestID: request.requestID, management.upsertAPISessionProfile(decodePayload(request.payload, as: APISessionProfile.self)))
        case .deleteAPISessionProfile:
            try management.deleteAPISessionProfile(decodePayload(request.payload, as: ControlPlaneNameRequest.self))
            return BrokerIPCResponse(requestID: request.requestID, ok: true)
        case .upsertMCPProfile:
            return try encodeResponse(requestID: request.requestID, management.upsertMCPProfile(decodePayload(request.payload, as: MCPUpstreamProfile.self)))
        case .deleteMCPProfile:
            try management.deleteMCPProfile(decodePayload(request.payload, as: ControlPlaneNameRequest.self))
            return BrokerIPCResponse(requestID: request.requestID, ok: true)
        case .upsertBitwardenBinding:
            return try encodeResponse(requestID: request.requestID, management.upsertBitwardenBinding(decodePayload(request.payload, as: BitwardenSecretBinding.self)))
        case .deleteBitwardenBinding:
            try management.deleteBitwardenBinding(decodePayload(request.payload, as: ControlPlaneNameRequest.self))
            return BrokerIPCResponse(requestID: request.requestID, ok: true)
        case .createManagedAPISession:
            return try encodeResponse(requestID: request.requestID, management.createAPISession(decodePayload(request.payload, as: ControlPlaneAPISessionRequest.self)))
        case .installAdapter:
            return try encodeResponse(requestID: request.requestID, management.installAdapter(decodePayload(request.payload, as: CommandPolicyPackPayload.self)))
        case .revokeAdapter:
            try management.revokeAdapter(decodePayload(request.payload, as: ControlPlaneNameRequest.self))
            return BrokerIPCResponse(requestID: request.requestID, ok: true)
        case .updateCommandPolicy:
            return try encodeResponse(requestID: request.requestID, management.updateCommandPolicy(decodePayload(request.payload, as: ControlPlaneCommandPolicyUpdateRequest.self)))
        case .clearDeliveryGrants:
            try management.clearDeliveryGrants()
            return BrokerIPCResponse(requestID: request.requestID, ok: true)
        case .exportRedactedAudit:
            return try encodeResponse(requestID: request.requestID, ["audit": management.exportRedactedAuditJSON()])
        case .createShimExecPlan:
            return try encodeResponse(
                requestID: request.requestID,
                management.createShimExecPlan(
                    decodePayload(request.payload, as: ShimExecPlanIPCRequest.self),
                    provenanceConfidence: observedPeer == nil ? .none : .socketPeer
                )
            )
        default:
            throw BrokerIPCError.unsupportedOperation(request.operation)
        }
    }

    private func decodePayload<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BrokerIPCError.malformedPayload
        }
    }

    private func encodeResponse<T: Encodable>(requestID: String, _ payload: T) throws -> BrokerIPCResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return BrokerIPCResponse(requestID: requestID, ok: true, payload: try encoder.encode(payload))
    }
}

public enum BrokerIPCCodec {
    public static func encodeRequest(_ request: BrokerIPCRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    public static func decodeRequest(_ data: Data) throws -> BrokerIPCRequest {
        do {
            return try JSONDecoder().decode(BrokerIPCRequest.self, from: data)
        } catch {
            throw BrokerIPCError.malformedPayload
        }
    }

    public static func encodeResponse(_ response: BrokerIPCResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(response)
    }

    public static func decodeResponse(_ data: Data) throws -> BrokerIPCResponse {
        do {
            return try JSONDecoder().decode(BrokerIPCResponse.self, from: data)
        } catch {
            throw BrokerIPCError.malformedPayload
        }
    }
}

public struct UnixDomainSocketIPCServer: Sendable {
    public var socketPath: String
    public var handler: BrokerIPCHandler

    public init(socketPath: String, handler: BrokerIPCHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func serveOnce() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw BrokerIPCError.socket(errnoDescription("socket")) }
        defer {
            close(serverFD)
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        var address = try makeUnixAddress(path: socketPath)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw BrokerIPCError.socket(errnoDescription("bind")) }
        guard listen(serverFD, 1) == 0 else { throw BrokerIPCError.socket(errnoDescription("listen")) }
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { throw BrokerIPCError.socket(errnoDescription("accept")) }
        defer { close(clientFD) }

        let requestData = try readFrame(from: clientFD)
        let response: BrokerIPCResponse
        do {
            let request = try BrokerIPCCodec.decodeRequest(requestData)
            let evidence = UnixSocketPeerEvidence.collect(fromAcceptedSocket: clientFD)
            let observedPeer = try evidence.selfBuildIdentity(helperName: request.peer.helperName, version: request.peer.version)
            response = try handler.handle(request, observedPeer: observedPeer)
        } catch {
            response = BrokerIPCResponse(requestID: "unknown", ok: false, error: String(describing: error))
        }
        try writeFrame(try BrokerIPCCodec.encodeResponse(response), to: clientFD)
    }
}

public extension UnixSocketPeerEvidence {
    static func collect(fromAcceptedSocket fd: Int32) -> UnixSocketPeerEvidence {
        var euid = uid_t()
        var egid = gid_t()
        if getpeereid(fd, &euid, &egid) != 0 {
            euid = getuid()
            egid = getgid()
        }
        let pid = peerPID(fromAcceptedSocket: fd)
        let path = pid.flatMap(executablePath(for:))
        let auditTokenAvailable = hasPeerAuditToken(fromAcceptedSocket: fd)
        return UnixSocketPeerEvidence(
            effectiveUserID: UInt32(euid),
            effectiveGroupID: UInt32(egid),
            processID: pid,
            executablePath: path,
            auditTokenAvailable: auditTokenAvailable,
            provenanceConfidence: path == nil ? .none : .socketPeer
        )
    }

    private static func peerPID(fromAcceptedSocket fd: Int32) -> Int32? {
        var pid = pid_t()
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = withUnsafeMutablePointer(to: &pid) { pointer in
            getsockopt(fd, solLocal, localPeerPID, pointer, &length)
        }
        guard result == 0, pid > 0 else {
            return nil
        }
        return pid
    }

    private static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: procPIDPathInfoMaxSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return buffer.withUnsafeBufferPointer { pointer in
            let bytes = pointer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func hasPeerAuditToken(fromAcceptedSocket fd: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, solLocal, localPeerToken, pointer, &length)
        }
        return result == 0
    }
}

public struct UnixDomainSocketIPCClient: Sendable {
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: BrokerIPCRequest) throws -> BrokerIPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerIPCError.socket(errnoDescription("socket")) }
        defer { close(fd) }
        var address = try makeUnixAddress(path: socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw BrokerIPCError.socket(errnoDescription("connect")) }
        try writeFrame(try BrokerIPCCodec.encodeRequest(request), to: fd)
        return try BrokerIPCCodec.decodeResponse(try readFrame(from: fd))
    }
}

private let solLocal: Int32 = 0
private let localPeerPID: Int32 = 0x002
private let localPeerToken: Int32 = 0x006
private let procPIDPathInfoMaxSize = 4096

private func makeUnixAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw BrokerIPCError.socket("socket path too long")
    }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        for index in bytes.indices {
            rawBuffer[index] = bytes[index]
        }
        rawBuffer[bytes.count] = 0
    }
    return address
}

private func readFrame(from fd: Int32) throws -> Data {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    try readExactly(into: &lengthBytes, from: fd)
    let length = UInt32(lengthBytes[0]) << 24 | UInt32(lengthBytes[1]) << 16 | UInt32(lengthBytes[2]) << 8 | UInt32(lengthBytes[3])
    guard length <= 1_048_576 else { throw BrokerIPCError.malformedPayload }
    var payload = [UInt8](repeating: 0, count: Int(length))
    try readExactly(into: &payload, from: fd)
    return Data(payload)
}

private func writeFrame(_ data: Data, to fd: Int32) throws {
    guard data.count <= 1_048_576 else { throw BrokerIPCError.malformedPayload }
    let length = UInt32(data.count)
    let lengthBytes: [UInt8] = [
        UInt8((length >> 24) & 0xff),
        UInt8((length >> 16) & 0xff),
        UInt8((length >> 8) & 0xff),
        UInt8(length & 0xff)
    ]
    try writeAll(lengthBytes, to: fd)
    try writeAll(Array(data), to: fd)
}

private func readExactly(into buffer: inout [UInt8], from fd: Int32) throws {
    var offset = 0
    while offset < buffer.count {
        let remaining = buffer.count - offset
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress!.advanced(by: offset), remaining)
        }
        guard count > 0 else { throw BrokerIPCError.socket(errnoDescription("read")) }
        offset += count
    }
}

private func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { rawBuffer in
            Darwin.write(fd, rawBuffer.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        guard count > 0 else { throw BrokerIPCError.socket(errnoDescription("write")) }
        offset += count
    }
}

private func errnoDescription(_ operation: String) -> String {
    "\(operation): \(String(cString: strerror(errno)))"
}

public struct IPCConformanceReport: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var transport: String
    public var messageTypes: [String]
    public var authorizationModel: [String]
    public var compatibilityStatus: String

    public init(
        protocolVersion: Int = BrokerIPC.protocolVersion,
        transport: String = BrokerIPC.transport,
        messageTypes: [String] = BrokerIPCOperation.allCases.map(\.rawValue).sorted(),
        authorizationModel: [String] = [
            "unix-domain-socket",
            "length-prefixed-json",
            "install-manifest",
            "resolved-path",
            "owner-user-id",
            "file-and-parent-permissions",
            "minimum-version",
            "binary-sha256",
            "optional-cdhash",
            "optional-debug-override",
            "server-observed-socket-peer",
            "getpeereid",
            "local-peer-pid",
            "local-peer-audit-token-best-effort"
        ],
        compatibilityStatus: String = "compatible"
    ) {
        self.protocolVersion = protocolVersion
        self.transport = transport
        self.messageTypes = messageTypes
        self.authorizationModel = authorizationModel
        self.compatibilityStatus = compatibilityStatus
    }
}
