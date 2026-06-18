import Foundation

public enum RemoteDeliveryPattern: String, Codable, Sendable {
    case oneShotSSHStdin = "one-shot-ssh-stdin"
    case remoteBitwardenMachineAccount = "remote-bws-machine-account"
    case cloudNativeIdentity = "cloud-native-identity"
    case remoteEnvFile = "remote-env-file"
}

public struct RemoteDeliveryContract: Codable, Equatable, Sendable {
    public var pattern: RemoteDeliveryPattern
    public var claim: String
    public var nonClaim: String
    public var requiresWarning: Bool
}

public enum RemoteDeliveryCatalog {
    public static let all: [RemoteDeliveryContract] = [
        .init(pattern: .oneShotSSHStdin, claim: "Secret is delivered over SSH stdin/fd to one remote command and is not stored locally in plaintext.", nonClaim: "Remote command can still log, persist, or exfiltrate it.", requiresWarning: true),
        .init(pattern: .remoteBitwardenMachineAccount, claim: "Local Mac does not ship application secrets; server uses its own scoped machine identity.", nonClaim: "Machine account blast radius is defined by upstream Bitwarden scope.", requiresWarning: false),
        .init(pattern: .cloudNativeIdentity, claim: "Workload receives cloud-native short-lived identity instead of a copied static secret.", nonClaim: "Cloud IAM policy quality is outside AgenticSecrets's local control.", requiresWarning: false),
        .init(pattern: .remoteEnvFile, claim: "Last-resort remote env/file delivery is explicit, audited, short-lived, and paired with cleanup.", nonClaim: "This is not secure remote environment storage.", requiresWarning: true)
    ]
}

