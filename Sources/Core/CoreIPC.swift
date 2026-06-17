import Foundation

public enum CoreIPC {
    public static let protocolVersion = 1
    public static let transport = "local-xpc-or-unix-domain-socket"
}

public enum CoreIPCOperation: String, Codable, CaseIterable, Sendable {
    case health
    case classifyCommand = "classify-command"
    case createDecisionManifest = "create-decision-manifest"
    case createApprovalSession = "create-approval-session"
    case createShimExecPlan = "create-shim-exec-plan"
    case createProxySession = "create-proxy-session"
    case bridgeMCPMessage = "bridge-mcp-message"
}

public struct CoreIPCRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var requestID: String
    public var operation: CoreIPCOperation
    public var peer: SelfBuildPeerIdentity
    public var payload: Data

    public init(
        version: Int = CoreIPC.protocolVersion,
        requestID: String,
        operation: CoreIPCOperation,
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

public struct CoreIPCResponse: Codable, Equatable, Sendable {
    public var version: Int
    public var requestID: String
    public var ok: Bool
    public var payload: Data
    public var error: String?

    public init(
        version: Int = CoreIPC.protocolVersion,
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

public enum CoreIPCError: Error, Equatable {
    case unsupportedVersion(Int)
    case unknownPeer(String)
    case unauthorizedPeer(String)
    case malformedPayload
}

public struct CoreIPCAuthorizer: Sendable {
    public var installManifest: InstallManifest

    public init(installManifest: InstallManifest) {
        self.installManifest = installManifest
    }

    public func authorize(_ request: CoreIPCRequest) throws {
        guard request.version == CoreIPC.protocolVersion else {
            throw CoreIPCError.unsupportedVersion(request.version)
        }
        guard let requirement = installManifest.requirement(for: request.peer.helperName) else {
            throw CoreIPCError.unknownPeer(request.peer.helperName)
        }
        do {
            try SelfBuildPeerValidator.validate(peer: request.peer, requirement: requirement)
        } catch {
            throw CoreIPCError.unauthorizedPeer(String(describing: error))
        }
    }
}

public struct IPCConformanceReport: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var transport: String
    public var messageTypes: [String]
    public var authorizationModel: [String]
    public var compatibilityStatus: String

    public init(
        protocolVersion: Int = CoreIPC.protocolVersion,
        transport: String = CoreIPC.transport,
        messageTypes: [String] = CoreIPCOperation.allCases.map(\.rawValue).sorted(),
        authorizationModel: [String] = [
            "install-manifest",
            "resolved-path",
            "owner-user-id",
            "file-and-parent-permissions",
            "minimum-version",
            "binary-sha256",
            "optional-cdhash",
            "optional-debug-override"
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
