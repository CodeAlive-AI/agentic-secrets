import AgenticFortressCore
import CryptoKit
import Dispatch
import Foundation
import LocalAuthentication
import Security

struct ContractTestFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

enum ContractTrustRefreshError: Error, Equatable {
    case denied
}

enum ContractDeliveryWitnessError: Error, Equatable {
    case blocked
}

struct BlockingDeliveryWitness: DeliveryWitness {
    func willReplaceSecret(alias: String, environment: String) throws {
        throw ContractDeliveryWitnessError.blocked
    }

    func didReplaceSecret(alias: String, environment: String) {}
}

final class ErrorBox: @unchecked Sendable {
    private var value: Error?
    private let lock = NSLock()

    func set(_ error: Error) {
        lock.withLock {
            value = error
        }
    }

    func get() -> Error? {
        lock.withLock {
            value
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw ContractTestFailure(message: message)
    }
}

func expectThrows<E: Error & Equatable>(_ expected: E, _ body: () throws -> Void, _ message: String) throws {
    do {
        try body()
    } catch let error as E {
        try expect(error == expected, "\(message): expected \(expected), got \(error)")
        return
    } catch {
        throw ContractTestFailure(message: "\(message): unexpected error \(error)")
    }
    throw ContractTestFailure(message: "\(message): expected error \(expected)")
}

func binding(actionClass: String = "hcloud.server.list", policyEpoch: Int = 1) -> InvocationBinding {
    InvocationBinding(
        peerIdentity: "peer:agentic-fortress-shim",
        injectorIdentity: "sig:agentic-fortress-shim",
        targetIdentity: "sha256:hcloud",
        actionClass: actionClass,
        workspace: "/tmp/infra",
        parentApp: "Codex",
        policyEpoch: policyEpoch,
        injectionMode: .env
    )
}

func signedPack(payload: AdapterPackPayload, key: P256.Signing.PrivateKey, keyID: String = "example-key") throws -> SignedAdapterPack {
    let signature = try key.signature(for: AdapterCanonicalizer.canonicalData(payload))
    return SignedAdapterPack(payload: payload, signatureBase64: signature.derRepresentation.base64EncodedString(), keyID: keyID)
}

func runContracts() throws {
    let classifier = CommandClassifier()
    let hcloudRead = classifier.classify(executableName: "hcloud", arguments: ["server", "list"], observedVersion: "1.52.0")
    try expect(hcloudRead.risk == .readOnly, "hcloud server list must be read-only")
    try expect(hcloudRead.confidence == .adapterTested, "hcloud read-only command must be adapter-tested")
    try expect(hcloudRead.adapterIdentity?.adapterID == "com.agenticfortress.adapters.hcloud", "hcloud classification must come from adapter registry")
    try expect(hcloudRead.adapterIdentity?.adapterHash.isEmpty == false, "adapter identity must include adapter hash")

    let customConfig = classifier.classify(executableName: "hcloud", arguments: ["--config", "./custom.toml", "server", "list"], observedVersion: "1.52.0")
    try expect(customConfig.leaseInvalidators.contains("config"), "custom hcloud config must invalidate remembered lease")

    let hcloudServerCreate = classifier.classify(executableName: "hcloud", arguments: ["server", "create", "--name", "codex-test", "--type", "cax11", "--image", "ubuntu-26.04", "--location", "fsn1"], observedVersion: "1.52.0")
    try expect(hcloudServerCreate.risk == .mutating, "hcloud server create with command flags must be mutating")
    try expect(hcloudServerCreate.confidence == .highRisk, "unknown hcloud mutating command must still require one-time approval")
    try expect(!hcloudServerCreate.leaseInvalidators.contains("unknown-flag"), "hcloud command-local flags must not invalidate unlock grants")

    let hcloudFirewallRule = classifier.classify(executableName: "hcloud", arguments: ["firewall", "add-rule", "codex-test", "--direction", "in", "--protocol", "tcp", "--port", "22", "--source-ips", "178.88.45.241/32"], observedVersion: "1.52.0")
    try expect(hcloudFirewallRule.risk == .mutating, "hcloud firewall add-rule with command flags must be mutating")

    let hcloudUnknownGlobal = classifier.classify(executableName: "hcloud", arguments: ["--plugin-mode", "server", "list"], observedVersion: "1.52.0")
    try expect(hcloudUnknownGlobal.risk == .unknown, "unknown hcloud global flags must remain high-risk unknown")

    let destructive = classifier.classify(executableName: "hcloud", arguments: ["server", "delete", "prod-db-01"], observedVersion: "1.52.0")
    let destructiveManifest = DecisionManifestFactory().make(
        command: destructive,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"),
        target: TargetAssessor().synthetic(path: "/opt/homebrew/bin/hcloud")
    )
    try expect(destructiveManifest.approvalOptions == [.once, .deny], "destructive actions must offer one-time approval only")
    try expect(!destructiveManifest.approvalOptions.contains(.readOnlyInWorkspace1h), "destructive actions must not offer remembered approval")
    try expect(destructiveManifest.typedChallenge == destructiveManifest.digest, "destructive manifest must expose typed challenge digest")

    let removeCommand = classifier.classify(executableName: "hcloud", arguments: ["server", "remove", "prod-db-01"], observedVersion: "1.52.0")
    try expect(removeCommand.risk == .destructive, "default command policy must treat remove as destructive")
    let destroyCommand = classifier.classify(executableName: "hcloud", arguments: ["server", "destroy", "prod-db-01"], observedVersion: "1.52.0")
    try expect(destroyCommand.risk != .destructive, "default command policy must not treat destroy as destructive")
    let customClassifier = CommandClassifier(commandPolicy: CommandPolicyConfig(destructiveTerms: ["remove"], forbiddenTerms: []))
    let deleteWithoutTerm = customClassifier.classify(executableName: "hcloud", arguments: ["server", "delete", "prod-db-01"], observedVersion: "1.52.0")
    try expect(deleteWithoutTerm.risk != .destructive, "removing delete from command policy must stop treating delete as destructive")
    let forbiddenClassifier = CommandClassifier(commandPolicy: CommandPolicyConfig(destructiveTerms: ["delete", "remove"], forbiddenTerms: ["delete"]))
    let forbiddenCommand = forbiddenClassifier.classify(executableName: "hcloud", arguments: ["server", "delete", "prod-db-01"], observedVersion: "1.52.0")
    let forbiddenManifest = DecisionManifestFactory().make(
        command: forbiddenCommand,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"),
        target: TargetAssessor().synthetic(path: "/opt/homebrew/bin/hcloud")
    )
    try expect(forbiddenManifest.approvalOptions == [.deny], "forbidden command policy must expose deny-only approval options")
    try expectThrows(PolicyError.forbiddenCommand("delete"), {
        _ = try PolicyEngine().authorize(command: forbiddenCommand, intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"), target: TargetAssessor().synthetic(path: "/opt/homebrew/bin/hcloud"), approval: .once, state: PolicyState())
    }, "forbidden command policy must block policy authorization")

    let approvalManifest = DecisionManifestFactory().make(
        command: hcloudRead,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"),
        target: TargetAssessor().synthetic(path: "/opt/homebrew/bin/hcloud")
    )
    let approvalStore = ApprovalSessionStore()
    let approval = approvalStore.create(manifest: approvalManifest, policyEpoch: 3, ttl: 10, now: Date(timeIntervalSince1970: 0))
    let validatedApproval = try approvalStore.validate(sessionID: approval.id, manifest: approvalManifest, policyEpoch: 3, now: Date(timeIntervalSince1970: 1))
    try expect(validatedApproval.manifestDigest == approvalManifest.digest, "approval session must bind manifest digest")
    try expectThrows(ApprovalSessionError.expired, {
        _ = try approvalStore.validate(sessionID: approval.id, manifest: approvalManifest, policyEpoch: 3, now: Date(timeIntervalSince1970: 11))
    }, "approval session must expire")
    let digestMismatchManifest = DecisionManifestFactory().make(
        command: hcloudRead,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/other", parentApp: "Codex"),
        target: TargetAssessor().synthetic(path: "/opt/homebrew/bin/hcloud")
    )
    let secondApproval = approvalStore.create(manifest: approvalManifest, policyEpoch: 3, ttl: 10, now: Date(timeIntervalSince1970: 20))
    try expectThrows(ApprovalSessionError.digestMismatch, {
        _ = try approvalStore.validate(sessionID: secondApproval.id, manifest: digestMismatchManifest, policyEpoch: 3, now: Date(timeIntervalSince1970: 21))
    }, "approval session must reject manifest digest mismatch")
    try expectThrows(ApprovalSessionError.policyEpochMismatch, {
        _ = try approvalStore.validate(sessionID: secondApproval.id, manifest: approvalManifest, policyEpoch: 4, now: Date(timeIntervalSince1970: 21))
    }, "approval session must reject policy epoch mismatch")

    let peerRequirement = CodeSigningRequirement(teamID: "TEAMID1234", bundleID: "com.agenticfortress.shim", minimumVersion: "1.2.0")
    try XPCPeerValidator.validate(peer: XPCPeerIdentity(teamID: "TEAMID1234", bundleID: "com.agenticfortress.shim", version: "1.2.1", hardenedRuntime: true), requirement: peerRequirement)
    try expectThrows(XPCPeerValidationError.wrongTeamID, {
        try XPCPeerValidator.validate(peer: XPCPeerIdentity(teamID: "OTHERTEAM", bundleID: "com.agenticfortress.shim", version: "1.2.1", hardenedRuntime: true), requirement: peerRequirement)
    }, "XPC peer validator must reject wrong Team ID")
    try expectThrows(XPCPeerValidationError.oldVersion, {
        try XPCPeerValidator.validate(peer: XPCPeerIdentity(teamID: "TEAMID1234", bundleID: "com.agenticfortress.shim", version: "1.1.9", hardenedRuntime: true), requirement: peerRequirement)
    }, "XPC peer validator must reject old helper versions")
    try expectThrows(XPCPeerValidationError.debugSignedRejected, {
        try XPCPeerValidator.validate(peer: XPCPeerIdentity(teamID: "TEAMID1234", bundleID: "com.agenticfortress.shim", version: "1.2.1", hardenedRuntime: true, debugSigned: true), requirement: peerRequirement)
    }, "XPC peer validator must reject debug-signed helpers by default")

    let helperRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-helper-\(UUID().uuidString)")
    let helperPath = helperRoot.appendingPathComponent("agentic-fortress-shim")
    try FileManager.default.createDirectory(at: helperRoot, withIntermediateDirectories: true)
    try "helper-binary".data(using: .utf8)!.write(to: helperPath)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperRoot.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath.path)
    let selfBuildPeer = try SelfBuildPeerValidator.identity(helperName: "agentic-fortress-shim", path: helperPath.path, version: "1.2.1", cdHash: "cdhash-demo")
    let selfBuildRequirement = SelfBuildPeerRequirement(
        helperName: selfBuildPeer.helperName,
        resolvedPath: selfBuildPeer.resolvedPath,
        ownerUserID: selfBuildPeer.ownerUserID,
        minimumVersion: "1.2.0",
        binarySHA256: selfBuildPeer.binarySHA256,
        cdHash: selfBuildPeer.cdHash
    )
    try SelfBuildPeerValidator.validate(peer: selfBuildPeer, requirement: selfBuildRequirement)
    var wrongHashPeer = selfBuildPeer
    wrongHashPeer.binarySHA256 = "sha256:wrong"
    try expectThrows(SelfBuildPeerValidationError.wrongHash, {
        try SelfBuildPeerValidator.validate(peer: wrongHashPeer, requirement: selfBuildRequirement)
    }, "self-build peer validator must reject wrong helper hash")
    var wrongPathPeer = selfBuildPeer
    wrongPathPeer.resolvedPath = "/tmp/agentic-fortress-shim"
    try expectThrows(SelfBuildPeerValidationError.wrongPath, {
        try SelfBuildPeerValidator.validate(peer: wrongPathPeer, requirement: selfBuildRequirement)
    }, "self-build peer validator must reject wrong helper path")
    var oldPeer = selfBuildPeer
    oldPeer.version = "1.1.9"
    try expectThrows(SelfBuildPeerValidationError.oldVersion, {
        try SelfBuildPeerValidator.validate(peer: oldPeer, requirement: selfBuildRequirement)
    }, "self-build peer validator must reject old helper versions")
    var writableParentPeer = selfBuildPeer
    writableParentPeer.parentMode = 0o777
    try expectThrows(SelfBuildPeerValidationError.worldWritableParent, {
        try SelfBuildPeerValidator.validate(peer: writableParentPeer, requirement: selfBuildRequirement)
    }, "self-build peer validator must reject world-writable helper parents")
    var debugPeer = selfBuildPeer
    debugPeer.debugSigned = true
    try expectThrows(SelfBuildPeerValidationError.debugSignedRejected, {
        try SelfBuildPeerValidator.validate(peer: debugPeer, requirement: selfBuildRequirement)
    }, "self-build peer validator must reject debug helpers without explicit override")
    var debugAllowedRequirement = selfBuildRequirement
    debugAllowedRequirement.allowDebugSigned = true
    try SelfBuildPeerValidator.validate(peer: debugPeer, requirement: debugAllowedRequirement)
    let installManifest = InstallManifest(appVersion: "1.2.1", prefix: helperRoot.path, installedAt: Date(timeIntervalSince1970: 0), helpers: [selfBuildRequirement])
    let ipcAuthorizer = CoreIPCAuthorizer(installManifest: installManifest)
    let ipcRequest = CoreIPCRequest(requestID: "req_1", operation: .health, peer: selfBuildPeer)
    try ipcAuthorizer.authorize(ipcRequest)
    try expectThrows(CoreIPCError.unsupportedVersion(999), {
        try ipcAuthorizer.authorize(CoreIPCRequest(version: 999, requestID: "req_2", operation: .health, peer: selfBuildPeer))
    }, "IPC authorizer must reject unknown protocol versions")
    try expectThrows(CoreIPCError.unauthorizedPeer("wrongHash"), {
        try ipcAuthorizer.authorize(CoreIPCRequest(requestID: "req_3", operation: .health, peer: wrongHashPeer))
    }, "IPC authorizer must reject helpers that fail self-build identity validation")
    try expectThrows(CoreIPCError.malformedPayload, {
        _ = try CoreIPCCodec.decodeRequest(Data("{".utf8))
    }, "IPC codec must reject malformed requests")
    let ipcSocket = "/tmp/af-\(shortDigest(UUID().uuidString, length: 10)).sock"
    try? FileManager.default.removeItem(atPath: ipcSocket)
    let serverDone = DispatchSemaphore(value: 0)
    let serverError = ErrorBox()
    DispatchQueue.global().async {
        do {
            try UnixDomainSocketIPCServer(
                socketPath: ipcSocket,
                handler: CoreIPCHandler(authorizer: ipcAuthorizer)
            ).serveOnce()
        } catch {
            serverError.set(error)
        }
        serverDone.signal()
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: ipcSocket) {
        Thread.sleep(forTimeInterval: 0.01)
    }
    let ipcResponse = try UnixDomainSocketIPCClient(socketPath: ipcSocket).send(ipcRequest)
    try expect(ipcResponse.ok, "Unix socket IPC health response must succeed")
    try expect(String(decoding: ipcResponse.payload, as: UTF8.self).contains("\"status\" : \"ok\""), "Unix socket IPC health payload must come from core handler")
    _ = serverDone.wait(timeout: .now() + 2)
    try expect(serverError.get() == nil, "Unix socket IPC server must complete without error")
    let ipcReport = IPCConformanceReport()
    try expect(ipcReport.protocolVersion == CoreIPC.protocolVersion, "IPC conformance must report current protocol version")
    try expect(ipcReport.messageTypes.contains(CoreIPCOperation.createShimExecPlan.rawValue), "IPC conformance must list shim exec plan operation")
    try expect(ipcReport.messageTypes.contains(CoreIPCOperation.loadManagementSnapshot.rawValue), "IPC conformance must list management snapshot operation")
    try expect(ipcReport.authorizationModel.contains("binary-sha256"), "IPC conformance must include hash-based self-build authorization")
    try? FileManager.default.removeItem(at: helperRoot)

    let managementRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentic-fortress-management-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: managementRoot) }
    let managementService = CoreManagementService(stateDirectory: managementRoot)
    let replaced = try managementService.replaceSecret(ManagementSecretReplacementRequest(
        alias: "cli.demo.demo_secret",
        value: "synthetic-management-value",
        label: "Demo Secret",
        environment: "cli:demo"
    ))
    try expect(replaced.alias == "cli.demo.demo_secret", "management secret replacement must return alias only")
    let managementSnapshot = try managementService.snapshot(now: Date(timeIntervalSince1970: 100))
    try expect(managementSnapshot.secrets.contains(where: { $0.alias == "cli.demo.demo_secret" }), "management snapshot must include secret summary")
    let encodedSnapshot = try AgenticFortressJSON.encodePretty(managementSnapshot)
    try expect(!encodedSnapshot.contains("synthetic-management-value"), "management snapshot must not contain raw secret value")
    try expect(!encodedSnapshot.contains("Bearer "), "management snapshot must not contain bearer tokens")
    try expectThrows(ManagementError.deleteSecretMaterialNotConfirmed, {
        try managementService.deleteSecret(ManagementSecretDeletionRequest(alias: "cli.demo.demo_secret", deleteSecretMaterial: false))
    }, "management secret deletion must require explicit material confirmation")
    try managementService.deleteSecret(ManagementSecretDeletionRequest(alias: "cli.demo.demo_secret", deleteSecretMaterial: true))
    let deletedSnapshot = try managementService.snapshot(now: Date(timeIntervalSince1970: 101))
    try expect(!deletedSnapshot.secrets.contains(where: { $0.alias == "cli.demo.demo_secret" }), "confirmed management secret deletion must remove secret summary")
    try expectThrows(ContractDeliveryWitnessError.blocked, {
        _ = try CoreManagementService(stateDirectory: managementRoot, witness: BlockingDeliveryWitness()).replaceSecret(ManagementSecretReplacementRequest(
            alias: "cli.demo.blocked",
            value: "synthetic-blocked-value",
            label: "Blocked",
            environment: "cli:demo"
        ))
    }, "delivery witness must be able to block management secret replacement")
    let proxyResponse = try managementService.createProxySession(ManagementProxySessionRequest(profileName: "openai", bindPort: 48177))
    try expect(!proxyResponse.oneTimeToken.isEmpty, "managed proxy session must return one-time token to caller")
    try expect(proxyResponse.session.tokenHash == stableDigest(proxyResponse.oneTimeToken), "managed proxy session must persist token hash only")
    let proxySnapshot = try managementService.snapshot(now: Date(timeIntervalSince1970: 102))
    let encodedProxySnapshot = try AgenticFortressJSON.encodePretty(proxySnapshot)
    try expect(!encodedProxySnapshot.contains(proxyResponse.oneTimeToken), "management snapshot must not persist one-time proxy token")

    let bwsSummary = try managementService.upsertBWSBinding(BWSSecretBinding(
        alias: "cloud.demo.dev",
        projectID: "project-demo",
        secretID: "bws-secret-id",
        environment: ProviderEnvironment.dev.rawValue
    ))
    try expect(bwsSummary.alias == "cloud.demo.dev", "management BWS upsert must return binding summary")
    try expect(bwsSummary.secretIDDigest.hasPrefix("sha256:"), "management BWS summary must expose only secret ID digest")
    let bwsSnapshot = try managementService.snapshot(now: Date(timeIntervalSince1970: 103))
    let encodedBWSSnapshot = try AgenticFortressJSON.encodePretty(bwsSnapshot)
    try expect(encodedBWSSnapshot.contains("cloud.demo.dev"), "management snapshot must include BWS binding alias")
    try expect(!encodedBWSSnapshot.contains("bws-secret-id"), "management snapshot must not expose raw BWS secret ID")
    try managementService.deleteBWSBinding(ManagementNameRequest(name: "cloud.demo.dev"))
    let deletedBWSSnapshot = try managementService.snapshot(now: Date(timeIntervalSince1970: 104))
    try expect(!deletedBWSSnapshot.bwsBindings.contains(where: { $0.alias == "cloud.demo.dev" }), "management BWS deletion must remove binding summary")

    let commandPolicy = try managementService.updateCommandPolicy(ManagementCommandPolicyUpdateRequest(
        destructiveTerms: [" remove ", "remove"],
        forbiddenTerms: ["shutdown"]
    ))
    try expect(commandPolicy.destructiveTerms == ["remove"], "management command policy update must normalize destructive terms")
    try expect(commandPolicy.forbiddenTerms == ["shutdown"], "management command policy update must normalize forbidden terms")
    let commandPolicySnapshot = try managementService.snapshot(now: Date(timeIntervalSince1970: 105))
    try expect(commandPolicySnapshot.commandPolicy.destructiveTerms == ["remove"], "management snapshot must include destructive command policy")
    try expect(commandPolicySnapshot.commandPolicy.forbiddenTerms == ["shutdown"], "management snapshot must include forbidden command policy")

    let managementHandler = CoreIPCHandler(authorizer: ipcAuthorizer, management: managementService)
    let commandPolicyIPCResponse = try managementHandler.handle(CoreIPCRequest(
        requestID: "req_command_policy",
        operation: .updateCommandPolicy,
        peer: selfBuildPeer,
        payload: try JSONEncoder().encode(ManagementCommandPolicyUpdateRequest(destructiveTerms: ["delete"], forbiddenTerms: []))
    ))
    try expect(commandPolicyIPCResponse.ok, "authorized management IPC command policy update must succeed")
    let managementIPCResponse = try managementHandler.handle(CoreIPCRequest(requestID: "req_management", operation: .loadManagementSnapshot, peer: selfBuildPeer))
    try expect(managementIPCResponse.ok, "authorized management IPC snapshot must succeed")
    let managementDecoder = JSONDecoder()
    managementDecoder.dateDecodingStrategy = .iso8601
    let decodedManagementSnapshot = try managementDecoder.decode(ManagementSnapshot.self, from: managementIPCResponse.payload)
    try expect(decodedManagementSnapshot.securityHealth.protocolVersion == CoreIPC.protocolVersion, "management IPC snapshot must decode typed payload")
    try expectThrows(CoreIPCError.unauthorizedPeer("wrongHash"), {
        _ = try managementHandler.handle(CoreIPCRequest(requestID: "req_management_bad_peer", operation: .loadManagementSnapshot, peer: wrongHashPeer))
    }, "management IPC must reject unauthorized peers")
    let fixedFixture = ManagementCLIRegistrationRequest(name: "demo", targetPath: "/bin/echo", environmentSecrets: ["DEMO_SECRET": "synthetic-management-value"])
    let decodedFixture = try JSONDecoder().decode(ManagementCLIRegistrationRequest.self, from: JSONEncoder().encode(fixedFixture))
    try expect(decodedFixture == fixedFixture, "management request fixtures must preserve typed Codable shape")

    let authReason = LocalAuthenticationGate.reason(for: approvalManifest)
    try expect(authReason.contains(approvalManifest.digest), "LocalAuthentication reason must include manifest digest")
    try expect(authReason.contains("provide HCLOUD_TOKEN to hcloud"), "LocalAuthentication reason must start with a readable approval phrase")
    try expect(authReason.contains("Command: hcloud server list"), "LocalAuthentication reason must include readable command")
    try expect(authReason.contains("Project: /tmp/infra"), "LocalAuthentication reason must include readable workspace")
    try expect(!authReason.contains(approvalManifest.secret.alias), "LocalAuthentication reason must not expose raw secret alias")
    try expect(authReason.contains("Secret: HCLOUD_TOKEN"), "LocalAuthentication reason must include target environment name")
    let authProof = LocalAuthenticationProof(manifestDigest: approvalManifest.digest, actionClass: approvalManifest.actionClass, reason: authReason, authenticatedAt: Date(timeIntervalSince1970: 0))
    try LocalAuthenticationGate.validate(proof: authProof, manifest: approvalManifest, now: Date(timeIntervalSince1970: 10))
    try expectThrows(LocalAuthenticationError.staleProof, {
        try LocalAuthenticationGate.validate(proof: authProof, manifest: approvalManifest, now: Date(timeIntervalSince1970: 31))
    }, "LocalAuthentication proof must expire quickly")
    try expectThrows(LocalAuthenticationError.digestMismatch, {
        try LocalAuthenticationGate.validate(proof: LocalAuthenticationProof(manifestDigest: "wrong", actionClass: approvalManifest.actionClass, reason: authReason, authenticatedAt: Date(timeIntervalSince1970: 0)), manifest: approvalManifest, now: Date(timeIntervalSince1970: 1))
    }, "LocalAuthentication proof must bind manifest digest")

    let unlockRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-unlock-\(UUID().uuidString)", isDirectory: true)
    let unlockStore = CLIUnlockGrantStore(
        url: unlockRoot.appendingPathComponent("cli-unlock-grants.json"),
        keyURL: unlockRoot.appendingPathComponent("cli-unlock-grants.key"),
        maxTTL: 300
    )
    let unlockScope = CLIUnlockScope(manifest: approvalManifest).withParentApp("Codex")
    let unlockGrant = try unlockStore.grant(scope: unlockScope, ttl: 120, now: Date(timeIntervalSince1970: 100))
    let validUnlockGrant = try unlockStore.validGrant(scope: unlockScope, now: Date(timeIntervalSince1970: 150))
    try expect(validUnlockGrant == unlockGrant, "CLI unlock grant must validate within TTL")
    let expiredUnlockGrant = try unlockStore.validGrant(scope: unlockScope, now: Date(timeIntervalSince1970: 221))
    try expect(expiredUnlockGrant == nil, "CLI unlock grant must expire")
    try expectThrows(CLIUnlockGrantError.invalidTTL, {
        _ = try unlockStore.grant(scope: unlockScope, ttl: 301, now: Date(timeIntervalSince1970: 100))
    }, "CLI unlock grant must cap TTL")
    let defaultUnlockRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-default-unlock-\(UUID().uuidString)", isDirectory: true)
    try expect(CLIUnlockGrantPolicy.defaultTTL == 300, "CLI unlock grant default TTL must be 300 seconds")
    try expect(CLIUnlockGrantPolicy.maxTTL == 900, "CLI unlock grant max TTL must be 900 seconds")
    let defaultUnlockStore = CLIUnlockGrantStore(
        url: defaultUnlockRoot.appendingPathComponent("cli-unlock-grants.json"),
        keyURL: defaultUnlockRoot.appendingPathComponent("cli-unlock-grants.key")
    )
    _ = try defaultUnlockStore.grant(scope: unlockScope, ttl: CLIUnlockGrantPolicy.maxTTL, now: Date(timeIntervalSince1970: 100))
    try expectThrows(CLIUnlockGrantError.invalidTTL, {
        _ = try defaultUnlockStore.grant(scope: unlockScope, ttl: CLIUnlockGrantPolicy.maxTTL + 1, now: Date(timeIntervalSince1970: 100))
    }, "CLI unlock grant default cap must match policy max TTL")
    let secondGrant = try unlockStore.grant(scope: unlockScope, ttl: 120, now: Date(timeIntervalSince1970: 300))
    let otherReadCommand = classifier.classify(executableName: "hcloud", arguments: ["location", "list"], observedVersion: "1.52.0")
    let otherReadManifest = DecisionManifestFactory().make(
        command: otherReadCommand,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"),
        target: TargetAssessor().synthetic(path: "/opt/homebrew/bin/hcloud")
    )
    try expect(otherReadManifest.actionClass != approvalManifest.actionClass, "test setup must use a different hcloud action class")
    let otherUnlockScope = CLIUnlockScope(manifest: otherReadManifest).withParentApp("Codex")
    let otherActionUnlockGrant = try unlockStore.validGrant(scope: otherUnlockScope, now: Date(timeIntervalSince1970: 301))
    try expect(otherActionUnlockGrant == secondGrant, "CLI unlock grant must apply across policy-authorized action classes for the same CLI secret scope")
    let unlockDecoder = JSONDecoder()
    unlockDecoder.dateDecodingStrategy = .iso8601
    var tamperedUnlockDocument = try unlockDecoder.decode(CLIUnlockGrantDocument.self, from: Data(contentsOf: unlockStore.url))
    tamperedUnlockDocument.grants[secondGrant.scopeDigest]?.expiresAt = Date(timeIntervalSince1970: 999999)
    let unlockEncoder = JSONEncoder()
    unlockEncoder.dateEncodingStrategy = .iso8601
    unlockEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try unlockEncoder.encode(tamperedUnlockDocument).write(to: unlockStore.url, options: [.atomic])
    try expectThrows(CLIUnlockGrantError.signatureMismatch, {
        _ = try unlockStore.validGrant(scope: unlockScope, now: Date(timeIntervalSince1970: 301))
    }, "CLI unlock grant must reject tampered expiry")
    try? FileManager.default.removeItem(at: unlockRoot)

    let secretStore = InMemorySecretStore()
    let secretAlias = SecretAlias("cloud.hcloud.dev")
    secretStore.put(
        binding: SecretBinding(alias: secretAlias, storeKind: "memory", externalID: "sec_hcloud", environment: "dev"),
        material: SecretMaterial(utf8: "super-secret-token")
    )
    let material = try secretStore.resolve(alias: secretAlias, approvedFor: validatedApproval)
    try material.withUTF8String { value in
        try expect(value == "super-secret-token", "secret store must resolve approved bound secret")
    }
    try expect(material.redactedDescription.contains("super-secret-token") == false, "secret material redacted description must not expose plaintext")
    try expectThrows(SecretStoreError.missingBinding(SecretAlias("missing.alias")), {
        _ = try secretStore.binding(for: SecretAlias("missing.alias"))
    }, "secret store must deny missing bindings")
    try expectThrows(SecretStoreError.accessDenied("approval-session-secret-mismatch"), {
        _ = try secretStore.resolve(alias: SecretAlias("other.alias"), approvedFor: validatedApproval)
    }, "secret store must bind secret resolution to approval session alias")
    let keychainDescriptor = KeychainSecretDescriptor(alias: secretAlias, service: "com.agenticfortress.test", account: "cloud.hcloud.dev", label: "HCloud dev", authentication: .presenceRequired)
    let keychainAddQuery = try KeychainSecretQueryFactory.addQuery(descriptor: keychainDescriptor, material: SecretMaterial(utf8: "query-secret"))
    try expect(keychainAddQuery[kSecUseDataProtectionKeychain] == nil, "Self-build Keychain add query must not require restricted data-protection Keychain entitlement")
    try expect(keychainAddQuery[kSecAttrAccessControl] != nil, "Keychain add query must use access control when user presence is required")
    try expect(KeychainSecretQueryFactory.accessControlFlags(for: .presenceRequired).contains(.userPresence), "presence-required Keychain policy must require user presence")
    try expect(KeychainSecretQueryFactory.accessControlFlags(for: .biometryCurrent).contains(.biometryCurrentSet), "biometry-current Keychain policy must bind current biometric set")
    let provisionedKeychainDescriptor = KeychainSecretDescriptor(alias: secretAlias, service: "com.agenticfortress.test", account: "cloud.hcloud.dev", label: "HCloud dev", authentication: .presenceRequired, backend: .dataProtectionKeychain)
    let provisionedKeychainAddQuery = try KeychainSecretQueryFactory.addQuery(descriptor: provisionedKeychainDescriptor, material: SecretMaterial(utf8: "query-secret"))
    try expect(provisionedKeychainAddQuery[kSecUseDataProtectionKeychain] as? Bool == true, "Provisioned Keychain backend must opt into data-protection Keychain explicitly")
    try expect(KeychainStorageBackend.loginKeychain.requiresRestrictedSigningEntitlement == false, "Default login Keychain backend must not require restricted signing entitlements")
    try expect(KeychainStorageBackend.dataProtectionKeychain.requiresRestrictedSigningEntitlement, "Data-protection Keychain backend must be treated as a provisioned-signing path")
    let keychainContext = LAContext()
    keychainContext.localizedReason = LocalAuthenticationGate.reason(for: approvalManifest)
    let keychainReadQuery = KeychainSecretQueryFactory.readQuery(descriptor: keychainDescriptor, context: keychainContext)
    try expect(keychainReadQuery[kSecUseAuthenticationContext] != nil, "Keychain read query must carry LAContext for approval prompt reason")
    try expect(keychainReadQuery[kSecUseDataProtectionKeychain] == nil, "Self-build Keychain read query must not require restricted data-protection Keychain entitlement")
    try expect(validatedApproval.authenticationReason == LocalAuthenticationGate.reason(for: approvalManifest), "approval session must carry full decision-bound LocalAuthentication reason")
    try expect(KeychainSecretStoreError.from(status: errSecUserCanceled) == .userCanceled, "Keychain user cancellation must fail closed with a distinct error")
    let keychainBinding = try KeychainSecretStore(service: "com.agenticfortress.test").binding(for: secretAlias)
    try expect(keychainBinding.storeKind == "keychain", "Keychain secret store must expose keychain binding metadata without plaintext")
    let systemSignedTool = "/bin/ls"
    if FileManager.default.fileExists(atPath: systemSignedTool) {
        let signatureAssessment = CodeSignatureInspector.assess(path: systemSignedTool)
        try expect(signatureAssessment.valid, "code signature inspector must validate signed system tools")
        try expect(signatureAssessment.designatedRequirement?.isEmpty == false, "code signature inspector must capture designated requirements when available")
        try expect(CodeSignatureInspector.satisfies(path: systemSignedTool, requirementText: signatureAssessment.designatedRequirement ?? ""), "code signature inspector must validate a tool against its captured requirement")
    }
    let encryptedStoreRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-local-secret-\(UUID().uuidString)", isDirectory: true)
    let encryptedStore = LocalEncryptedSecretStore(
        storeURL: encryptedStoreRoot.appendingPathComponent("secrets.json"),
        keyURL: encryptedStoreRoot.appendingPathComponent("secret-store.key")
    )
    let localSecretAlias = SecretAlias("local.encrypted.dev")
    try encryptedStore.store(alias: localSecretAlias, material: SecretMaterial(utf8: "local-store-secret"), label: "Local encrypted dev")
    defer { try? FileManager.default.removeItem(at: encryptedStoreRoot) }
    let encryptedBinding = try encryptedStore.binding(for: localSecretAlias)
    try expect(encryptedBinding.storeKind == "local-encrypted-file", "self-build secret store must expose local encrypted binding metadata")
    let encryptedStoreBytes = try Data(contentsOf: encryptedStore.storeURL)
    let encryptedStoreText = String(decoding: encryptedStoreBytes, as: UTF8.self)
    try expect(!encryptedStoreText.contains("local-store-secret"), "local encrypted store file must not contain plaintext secret material")
    let keyBytes = try Data(contentsOf: encryptedStore.keyURL)
    try expect(keyBytes.count == 32, "local encrypted store key must be 256 bits")
    let storePermissions = try FileManager.default.attributesOfItem(atPath: encryptedStore.storeURL.path)[.posixPermissions] as? NSNumber
    let keyPermissions = try FileManager.default.attributesOfItem(atPath: encryptedStore.keyURL.path)[.posixPermissions] as? NSNumber
    try expect(storePermissions?.intValue == 0o600, "local encrypted store file must be owner-only")
    try expect(keyPermissions?.intValue == 0o600, "local encrypted store key file must be owner-only")
    let userCancelError = NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue)
    try expect(LocalAuthenticationPolicyGate.map(error: userCancelError) == .userCanceled, "LocalAuthentication cancellation must fail closed with userCanceled")

    let registrationRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-cli-registration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: registrationRoot, withIntermediateDirectories: true)
    let registeredTarget = registrationRoot.appendingPathComponent("hcloud")
    try "#!/bin/sh\nexit 0\n".data(using: .utf8)!.write(to: registeredTarget)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: registeredTarget.path)
    let registrationLayout = AgenticFortressStateLayout(stateDirectory: registrationRoot.appendingPathComponent("state", isDirectory: true))
    let registrationProtector = HMACCLIRegistryIntegrityProtector(
        keyID: "contract-test-registry-key",
        keyData: Data(repeating: 0xA7, count: 32)
    )
    let registrationService = CLIRegistrationService(
        registryStore: CLIRegistrationStore(registryURL: registrationLayout.registryURL, integrityProtector: registrationProtector),
        secretStore: LocalEncryptedSecretStore(storeURL: registrationLayout.secretStoreURL, keyURL: registrationLayout.secretKeyURL)
    )
    let legacyRegistryRoot = registrationRoot.appendingPathComponent("legacy-empty-registry", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyRegistryRoot, withIntermediateDirectories: true)
    let legacyRegistryStore = CLIRegistrationStore(
        registryURL: legacyRegistryRoot.appendingPathComponent("cli-registry.json"),
        integrityProtector: registrationProtector
    )
    try Data(#"{"registrations":{},"schemaVersion":1}"#.utf8).write(to: legacyRegistryStore.registryURL, options: [.atomic])
    let legacyRegistryDocument = try legacyRegistryStore.load()
    try expect(legacyRegistryDocument == CLIRegistrationDocument(), "empty legacy CLI registry without sidecar must bootstrap for first registration")
    try legacyRegistryStore.save(CLIRegistrationDocument())
    try expect(FileManager.default.fileExists(atPath: legacyRegistryStore.integrityURL.path), "empty legacy CLI registry bootstrap must write integrity sidecar on save")
    let registration = try registrationService.register(
        name: "hcloud",
        targetPath: registeredTarget.path,
        environmentValues: ["HCLOUD_TOKEN": SecretMaterial(utf8: "registration-secret-token")],
        now: Date(timeIntervalSince1970: 0)
    )
    try expect(registration.name == "hcloud", "CLI registration must preserve command name")
    try expect(registration.targetPath == registeredTarget.path, "CLI registration must persist resolved target path")
    try expect(registration.targetIdentity?.hasPrefix("sha256:") == true, "CLI registration must pin assessed target identity")
    try expect(registration.environmentBindings == [CLIEnvironmentBinding(environmentName: "HCLOUD_TOKEN", secretAlias: "cli.hcloud.hcloud_token")], "CLI registration must bind env name to deterministic secret alias")
    let loadedRegistration = try registrationService.registration(named: "hcloud")
    try expect(loadedRegistration == registration, "CLI run path must load registration metadata by name")
    let registryText = String(decoding: try Data(contentsOf: registrationLayout.registryURL), as: UTF8.self)
    try expect(registryText.contains("HCLOUD_TOKEN"), "CLI registry must store env metadata")
    try expect(!registryText.contains("registration-secret-token"), "CLI registry must not store plaintext secret values")
    try expect(FileManager.default.fileExists(atPath: registrationService.registryStore.integrityURL.path), "CLI registry must write an integrity sidecar")
    let integrityPermissions = try FileManager.default.attributesOfItem(atPath: registrationService.registryStore.integrityURL.path)[.posixPermissions] as? NSNumber
    try expect(integrityPermissions?.intValue == 0o600, "CLI registry integrity sidecar must be owner-only")
    let tamperedRegistryText = registryText.replacingOccurrences(of: registration.targetIdentity ?? "sha256:missing", with: "sha256:attacker")
    try tamperedRegistryText.data(using: .utf8)!.write(to: registrationLayout.registryURL, options: [.atomic])
    try expectThrows(CLIRegistryIntegrityError.signatureMismatch, {
        _ = try registrationService.registryStore.load()
    }, "CLI registry load must fail closed when trust metadata is modified outside AgenticFortress")
    try registryText.data(using: .utf8)!.write(to: registrationLayout.registryURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registrationLayout.registryURL.path)
    let registeredSecretStoreText = String(decoding: try Data(contentsOf: registrationLayout.secretStoreURL), as: UTF8.self)
    try expect(!registeredSecretStoreText.contains("registration-secret-token"), "CLI local encrypted store must not contain plaintext registered secret")
    let registryPermissions = try FileManager.default.attributesOfItem(atPath: registrationLayout.registryURL.path)[.posixPermissions] as? NSNumber
    try expect(registryPermissions?.intValue == 0o600, "CLI registry must be owner-only")
    let symlinkRoot = registrationRoot.appendingPathComponent("symlink-case", isDirectory: true)
    let cellarRoot = symlinkRoot.appendingPathComponent("Cellar/hcloud/1.65.0/bin", isDirectory: true)
    let binRoot = symlinkRoot.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: cellarRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: binRoot, withIntermediateDirectories: true)
    let versionedHcloud = cellarRoot.appendingPathComponent("hcloud")
    let stableHcloud = binRoot.appendingPathComponent("hcloud")
    try "#!/bin/sh\nexit 0\n".data(using: .utf8)!.write(to: versionedHcloud)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: versionedHcloud.path)
    try FileManager.default.createSymbolicLink(atPath: stableHcloud.path, withDestinationPath: "../Cellar/hcloud/1.65.0/bin/hcloud")
    let symlinkRegistration = try registrationService.register(
        name: "hcloud-symlink",
        targetPath: stableHcloud.path,
        environmentValues: ["HCLOUD_TOKEN": SecretMaterial(utf8: "symlink-secret-token")],
        now: Date(timeIntervalSince1970: 0)
    )
    try expect(symlinkRegistration.targetPath == stableHcloud.path, "CLI registration must keep stable symlink invocation path across CLI upgrades")
    let originalSymlinkTarget = try TargetAssessor().assess(path: symlinkRegistration.targetPath)
    try registrationService.validateTargetIdentity(registration: symlinkRegistration, assessedTarget: originalSymlinkTarget)
    let upgradedCellarRoot = symlinkRoot.appendingPathComponent("Cellar/hcloud/1.66.0/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: upgradedCellarRoot, withIntermediateDirectories: true)
    let upgradedHcloud = upgradedCellarRoot.appendingPathComponent("hcloud")
    try "#!/bin/sh\nexit 0\n# changed\n".data(using: .utf8)!.write(to: upgradedHcloud)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: upgradedHcloud.path)
    try FileManager.default.removeItem(at: stableHcloud)
    try FileManager.default.createSymbolicLink(atPath: stableHcloud.path, withDestinationPath: "../Cellar/hcloud/1.66.0/bin/hcloud")
    let changedSymlinkTarget = try TargetAssessor().assess(path: symlinkRegistration.targetPath)
    try expectThrows(CLIRegistrationError.targetIdentityChanged(name: "hcloud-symlink", expected: symlinkRegistration.targetIdentity ?? "", actual: changedSymlinkTarget.identity), {
        try registrationService.validateTargetIdentity(registration: symlinkRegistration, assessedTarget: changedSymlinkTarget)
    }, "CLI run path must deny target binary replacement before resolving secrets")
    let registrationBeforeDeniedRefresh = try registrationService.registration(named: "hcloud-symlink")
    var deniedRefreshRequest: CLITrustRefreshAuthorizationRequest?
    try expectThrows(ContractTrustRefreshError.denied, {
        _ = try registrationService.refreshTargetTrust(name: "hcloud-symlink") { request in
            deniedRefreshRequest = request
            throw ContractTrustRefreshError.denied
        }
    }, "trust refresh must require authorization before updating target identity")
    try expect(deniedRefreshRequest?.currentIdentity == symlinkRegistration.targetIdentity, "trust refresh authorization must include current identity")
    try expect(deniedRefreshRequest?.proposedIdentity == changedSymlinkTarget.identity, "trust refresh authorization must include proposed identity")
    let registrationAfterDeniedRefresh = try registrationService.registration(named: "hcloud-symlink")
    try expect(registrationAfterDeniedRefresh == registrationBeforeDeniedRefresh, "denied trust refresh must not modify registry metadata")

    let raceCellarRoot = symlinkRoot.appendingPathComponent("Cellar/hcloud/1.67.0/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: raceCellarRoot, withIntermediateDirectories: true)
    let raceHcloud = raceCellarRoot.appendingPathComponent("hcloud")
    try "#!/bin/sh\nexit 0\n# changed again\n".data(using: .utf8)!.write(to: raceHcloud)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: raceHcloud.path)
    try expectThrows(CLIRegistrationError.targetChangedDuringTrustRefresh(name: "hcloud-symlink"), {
        _ = try registrationService.refreshTargetTrust(name: "hcloud-symlink") { _ in
            try FileManager.default.removeItem(at: stableHcloud)
            try FileManager.default.createSymbolicLink(atPath: stableHcloud.path, withDestinationPath: "../Cellar/hcloud/1.67.0/bin/hcloud")
        }
    }, "trust refresh must fail closed if target changes between authorization and write")
    let racedSymlinkTarget = try TargetAssessor().assess(path: symlinkRegistration.targetPath)
    let refreshedSymlinkRegistration = try registrationService.refreshTargetTrust(name: "hcloud-symlink") { request in
        try expect(request.currentIdentity == symlinkRegistration.targetIdentity, "authorized trust refresh must show old target identity")
        try expect(request.proposedIdentity == racedSymlinkTarget.identity, "authorized trust refresh must show current replacement identity")
    }
    try expect(refreshedSymlinkRegistration.environmentBindings == symlinkRegistration.environmentBindings, "trust refresh must not change secret bindings")
    try expect(refreshedSymlinkRegistration.targetPath == stableHcloud.path, "trust refresh must keep stable invocation path")
    try expect(refreshedSymlinkRegistration.targetIdentity == racedSymlinkTarget.identity, "trust refresh must update pinned target identity")
    try registrationService.validateTargetIdentity(registration: refreshedSymlinkRegistration, assessedTarget: racedSymlinkTarget)
    try expectThrows(CLIRegistrationError.invalidEnvironmentName("HCLOUD_TOKEN=leak"), {
        _ = try registrationService.register(
            name: "hcloud",
            targetPath: registeredTarget.path,
            environmentValues: ["HCLOUD_TOKEN=leak": SecretMaterial(utf8: "bad")],
            now: Date(timeIntervalSince1970: 0)
        )
    }, "CLI registration must reject env specs that include values in argument-shaped names")
    let removedRegistration = try registrationService.unregister(name: "hcloud", deleteSecrets: true)
    try expect(removedRegistration.name == "hcloud", "CLI unregister must return removed registration")
    let registryAfterDelete = try registrationService.registryStore.load()
    try expect(registryAfterDelete.registrations["hcloud"] == nil, "CLI unregister must remove registration metadata")
    try expectThrows(SecretStoreError.missingBinding(SecretAlias("cli.hcloud.hcloud_token")), {
        _ = try registrationService.secretStore.binding(for: SecretAlias("cli.hcloud.hcloud_token"))
    }, "CLI unregister with delete-secrets must remove secret binding")
    try? FileManager.default.removeItem(at: registrationRoot)

    let multiInjectedEnvironment = try EnvironmentScrubber().scrub(
        parent: ["PATH": "/usr/bin", "BWS_ACCESS_TOKEN": "drop-me", "SAFE": "keep"],
        injectedValues: ["HCLOUD_TOKEN": "hcloud-value", "DEMO_TOKEN": "demo-value"]
    )
    try expect(multiInjectedEnvironment["PATH"] == "/usr/bin", "multi-env scrub must keep non-secret parent env")
    try expect(multiInjectedEnvironment["SAFE"] == "keep", "multi-env scrub must keep safe parent env")
    try expect(multiInjectedEnvironment["BWS_ACCESS_TOKEN"] == nil, "multi-env scrub must remove inherited secret-like env")
    try expect(multiInjectedEnvironment["HCLOUD_TOKEN"] == "hcloud-value", "multi-env scrub must inject first target env")
    try expect(multiInjectedEnvironment["DEMO_TOKEN"] == "demo-value", "multi-env scrub must inject second target env")
    try expectThrows(EnvironmentScrubError.targetAlreadyPresent("HCLOUD_TOKEN"), {
        _ = try EnvironmentScrubber().scrub(parent: ["HCLOUD_TOKEN": "ambient"], injectedValues: ["HCLOUD_TOKEN": "fresh"])
    }, "multi-env scrub must fail closed on ambient target collision")

    try expect(CLIShimPolicy.isGlobalPassThrough(arguments: ["--help"]), "shim must pass global --help without secret delivery")
    try expect(CLIShimPolicy.isGlobalPassThrough(arguments: ["server", "--help"]), "shim must pass nested --help without secret delivery")
    try expect(CLIShimPolicy.isGlobalPassThrough(arguments: ["help", "server"]), "shim must pass help subcommands without secret delivery")
    try expect(CLIShimPolicy.isGlobalPassThrough(arguments: ["--version"]), "shim must pass --version without secret delivery")
    try expect(CLIShimPolicy.isGlobalPassThrough(arguments: ["version"]), "shim must pass version subcommand without secret delivery")
    try expect(!CLIShimPolicy.isGlobalPassThrough(arguments: ["-v"]), "shim must not treat ambiguous -v as a global version exception")
    try expect(!CLIShimPolicy.isGlobalPassThrough(arguments: ["server", "list"]), "shim must route normal commands through AgenticFortress")

    let shimRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-shim-\(UUID().uuidString)")
    let shimTarget = shimRoot.appendingPathComponent("hcloud")
    try FileManager.default.createDirectory(at: shimRoot, withIntermediateDirectories: true)
    try "fake hcloud".data(using: .utf8)!.write(to: shimTarget)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimRoot.path)
    let shimPolicy = TargetPolicy(commandName: "hcloud", targetPath: shimTarget.path, secretAlias: "cloud.hcloud.dev", environmentName: "HCLOUD_TOKEN")
    let shimRequest = ShimRequest(invokedName: "/tmp/spoofable/hcloud", arguments: ["server", "list"], parentEnvironment: ["PATH": "/usr/bin", "BWS_ACCESS_TOKEN": "drop-me"], workspace: "/tmp/infra", parentApp: "Codex", peerIdentity: "peer:agentic-fortress-shim", injectorIdentity: "sig:agentic-fortress-shim")
    let shimCommand = classifier.classify(executableName: "hcloud", arguments: ["server", "list"])
    let shimTargetAssessment = try TargetAssessor().assess(path: shimTarget.path)
    let shimManifest = DecisionManifestFactory().make(
        command: shimCommand,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"),
        target: shimTargetAssessment
    )
    let shimApprovals = ApprovalSessionStore()
    let shimApproval = shimApprovals.create(manifest: shimManifest, policyEpoch: 1, ttl: 30, now: Date(timeIntervalSince1970: 0))
    let shimHandles = InvocationHandleStore()
    let shimAudit = AuditLog()
    let execPlan = try ShimExecutionPlanner().plan(
        request: shimRequest,
        targetPolicies: [shimPolicy],
        policyState: PolicyState(epoch: 1),
        approvalSessionID: shimApproval.id,
        approvalSessions: shimApprovals,
        secrets: secretStore,
        handles: shimHandles,
        audit: shimAudit,
        now: Date(timeIntervalSince1970: 1)
    )
    let shimAuditEvents = shimAudit.snapshot()
    try expect(shimAuditEvents.count == 1, "shim planner must write one audit event for approved delivery")
    try expect(shimAuditEvents[0].decisionDigest == execPlan.manifest.digest, "audit event must include decision digest")
    try expect(shimAuditEvents[0].targetIdentity == execPlan.target.identity, "audit event must include target identity")
    try expect(shimAuditEvents[0].workspaceHash == execPlan.manifest.workspace.canonicalHash, "audit event must include workspace hash")
    try expect(shimAuditEvents[0].outcome == "exec-plan-created", "audit event must include approved outcome")
    try expect(execPlan.targetPath == shimTarget.path, "shim planner must resolve target from policy, not argv")
    try expect(execPlan.environment["BWS_ACCESS_TOKEN"] == nil, "shim planner must scrub inherited secret-like env")
    try expect(execPlan.environment["HCLOUD_TOKEN"] == "super-secret-token", "shim planner must inject approved secret into fresh env")
    let execBinding = InvocationBinding(peerIdentity: "peer:agentic-fortress-shim", injectorIdentity: "sig:agentic-fortress-shim", targetIdentity: execPlan.target.identity, actionClass: "hcloud.server.list", workspace: "/tmp/infra", parentApp: "Codex", policyEpoch: 1, injectionMode: .env)
    try shimHandles.consume(execPlan.invocationHandle, expectedBinding: execBinding, now: Date(timeIntervalSince1970: 2))
    try expectThrows(InvocationHandleError.unknown, {
        try shimHandles.consume(execPlan.invocationHandle, expectedBinding: execBinding, now: Date(timeIntervalSince1970: 3))
    }, "shim invocation handle must be single-use")
    try expectThrows(EnvironmentScrubError.targetAlreadyPresent("HCLOUD_TOKEN"), {
        _ = try ShimExecutionPlanner().plan(
            request: ShimRequest(invokedName: "hcloud", arguments: ["server", "list"], parentEnvironment: ["HCLOUD_TOKEN": "ambient"], workspace: "/tmp/infra", parentApp: "Codex", peerIdentity: "peer:agentic-fortress-shim", injectorIdentity: "sig:agentic-fortress-shim"),
            targetPolicies: [shimPolicy],
            policyState: PolicyState(epoch: 1),
            approvalSessionID: shimApproval.id,
            approvalSessions: shimApprovals,
            secrets: secretStore,
            handles: InvocationHandleStore(),
            now: Date(timeIntervalSince1970: 1)
        )
    }, "shim planner must fail closed on ambient target env collision")
    try expectThrows(ShimPlannerError.unknownTarget("unknown"), {
        _ = try ShimExecutionPlanner().plan(
            request: ShimRequest(invokedName: "unknown", arguments: [], parentEnvironment: [:], workspace: "/tmp/infra", parentApp: "Codex", peerIdentity: "peer", injectorIdentity: "sig"),
            targetPolicies: [shimPolicy],
            policyState: PolicyState(epoch: 1),
            approvalSessionID: shimApproval.id,
            approvalSessions: shimApprovals,
            secrets: secretStore,
            handles: InvocationHandleStore(),
            now: Date(timeIntervalSince1970: 1)
        )
    }, "shim planner must reject unknown symlink command names")
    let destructiveShimCommand = classifier.classify(executableName: "hcloud", arguments: ["server", "delete", "prod-db-01"])
    let destructiveShimManifest = DecisionManifestFactory().make(
        command: destructiveShimCommand,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"),
        target: shimTargetAssessment
    )
    let destructiveApproval = shimApprovals.create(manifest: destructiveShimManifest, policyEpoch: 1, ttl: 30, now: Date(timeIntervalSince1970: 0))
    let destructiveAudit = AuditLog()
    let destructivePlan = try ShimExecutionPlanner().plan(
        request: ShimRequest(invokedName: "hcloud", arguments: ["server", "delete", "prod-db-01"], parentEnvironment: [:], workspace: "/tmp/infra", parentApp: "Codex", peerIdentity: "peer:agentic-fortress-shim", injectorIdentity: "sig:agentic-fortress-shim"),
        targetPolicies: [shimPolicy],
        policyState: PolicyState(epoch: 1),
        approvalSessionID: destructiveApproval.id,
        approvalSessions: shimApprovals,
        secrets: secretStore,
        handles: InvocationHandleStore(),
        audit: destructiveAudit,
        now: Date(timeIntervalSince1970: 1)
    )
    try expect(destructivePlan.environment["HCLOUD_TOKEN"] == "super-secret-token", "shim planner must inject approved secret for destructive registered hcloud commands")
    try expect(destructiveAudit.snapshot().first?.decision == "allow", "destructive registered hcloud delivery must write an allow audit event")
    let forbiddenShimClassifier = CommandClassifier(commandPolicy: CommandPolicyConfig(destructiveTerms: ["delete", "remove"], forbiddenTerms: ["delete"]))
    let forbiddenShimCommand = forbiddenShimClassifier.classify(executableName: "hcloud", arguments: ["server", "delete", "prod-db-01"])
    let forbiddenShimManifest = DecisionManifestFactory().make(
        command: forbiddenShimCommand,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"),
        target: shimTargetAssessment
    )
    let forbiddenShimApproval = shimApprovals.create(manifest: forbiddenShimManifest, policyEpoch: 1, ttl: 30, now: Date(timeIntervalSince1970: 0))
    let forbiddenShimAudit = AuditLog()
    try expectThrows(PolicyError.forbiddenCommand("delete"), {
        _ = try ShimExecutionPlanner(classifier: forbiddenShimClassifier).plan(
            request: ShimRequest(invokedName: "hcloud", arguments: ["server", "delete", "prod-db-01"], parentEnvironment: [:], workspace: "/tmp/infra", parentApp: "Codex", peerIdentity: "peer:agentic-fortress-shim", injectorIdentity: "sig:agentic-fortress-shim"),
            targetPolicies: [shimPolicy],
            policyState: PolicyState(epoch: 1),
            approvalSessionID: forbiddenShimApproval.id,
            approvalSessions: shimApprovals,
            secrets: secretStore,
            handles: InvocationHandleStore(),
            audit: forbiddenShimAudit,
            now: Date(timeIntervalSince1970: 1)
        )
    }, "shim planner must deny forbidden command policy matches before secret delivery")
    try expect(forbiddenShimAudit.snapshot().first?.decision == "deny", "forbidden shim command must write a deny audit event")
    let npmTarget = shimRoot.appendingPathComponent("npm")
    try "fake npm".data(using: .utf8)!.write(to: npmTarget)
    let npmPolicy = TargetPolicy(commandName: "npm", targetPath: npmTarget.path, secretAlias: "cloud.hcloud.dev", environmentName: "OPENAI_API_KEY")
    let npmCommand = CommandClassifier().classify(executableName: "npm", arguments: ["run", "dev"])
    let npmManifest = DecisionManifestFactory().make(
        command: npmCommand,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "OPENAI_API_KEY", workspace: "/tmp/infra", parentApp: "Codex"),
        target: try TargetAssessor().assess(path: npmTarget.path)
    )
    let npmApproval = shimApprovals.create(manifest: npmManifest, policyEpoch: 1, ttl: 30, now: Date(timeIntervalSince1970: 0))
    try expectThrows(PolicyError.genericEnvDenied, {
        _ = try ShimExecutionPlanner().plan(
            request: ShimRequest(invokedName: "npm", arguments: ["run", "dev"], parentEnvironment: [:], workspace: "/tmp/infra", parentApp: "Codex", peerIdentity: "peer", injectorIdentity: "sig"),
            targetPolicies: [npmPolicy],
            policyState: PolicyState(epoch: 1),
            approvalSessionID: npmApproval.id,
            approvalSessions: shimApprovals,
            secrets: secretStore,
            handles: InvocationHandleStore(),
            now: Date(timeIntervalSince1970: 1)
        )
    }, "shim planner must deny raw env delivery to generic runners")
    try? FileManager.default.removeItem(at: shimRoot)

    let unknownFlag = classifier.classify(executableName: "hcloud", arguments: ["--plugin-mode", "server", "list"], observedVersion: "1.52.0")
    try expect(unknownFlag.risk == .unknown, "unknown adapter flags must classify as unknown")
    try expect(unknownFlag.leaseInvalidators.contains("unknown-flag"), "unknown adapter flags must invalidate remembered leases")

    let ghContext = classifier.classify(executableName: "gh", arguments: ["--repo", "owner/repo", "issue", "list"], observedVersion: "2.0.0")
    try expect(ghContext.risk == .readOnly, "known gh issue list should remain read-only")
    try expect(ghContext.leaseInvalidators.contains("repo"), "gh repo context must invalidate remembered leases")

    let terraform = classifier.classify(executableName: "terraform", arguments: ["plan"])
    try expect(terraform.risk == .unknown, "terraform must remain high-risk/generic despite built-in metadata")

    let generic = CommandClassifier().classify(executableName: "npm", arguments: ["run", "dev"])
    try expectThrows(PolicyError.genericEnvDenied, {
        _ = try PolicyEngine().authorize(
            command: generic,
            intent: DeliveryIntent(flow: .cliEnv, secretAlias: "ai.openai.dev", delivery: .env, environmentName: "OPENAI_API_KEY", workspace: "/tmp/app", parentApp: "Codex"),
            target: TargetAssessor().synthetic(path: "/opt/homebrew/bin/npm"),
            approval: .once,
            state: PolicyState()
        )
    }, "generic runners must deny raw env secrets")

    let store = InvocationHandleStore()
    let handle = try store.create(binding: binding(), ttl: 30, maxUses: 1)
    try store.consume(handle, expectedBinding: binding())
    try expectThrows(InvocationHandleError.unknown, {
        try store.consume(handle, expectedBinding: binding())
    }, "invocation handle replay must fail")
    let wrongBindingHandle = try store.create(binding: binding(), ttl: 30, maxUses: 1)
    try expectThrows(InvocationHandleError.wrongBinding, {
        try store.consume(wrongBindingHandle, expectedBinding: binding(actionClass: "hcloud.server.delete"))
    }, "invocation handle must bind action class")
    try expectThrows(InvocationHandleError.invalidTTL, {
        _ = try store.create(binding: binding(), ttl: 31, maxUses: 1)
    }, "invocation handle TTL must be capped")
    try expectThrows(InvocationHandleError.invalidTTL, {
        _ = try store.create(binding: binding(), ttl: 10, maxUses: 4)
    }, "invocation handle max uses must be capped")

    let scrubbed = try EnvironmentScrubber().scrub(
        parent: ["PATH": "/usr/bin", "BWS_ACCESS_TOKEN": "x", "SOME_API_KEY": "y"],
        targetEnvironmentName: "HCLOUD_TOKEN",
        injectedValue: "test-token"
    )
    try expect(scrubbed["BWS_ACCESS_TOKEN"] == nil && scrubbed["SOME_API_KEY"] == nil, "environment scrubber must remove secret-like variables")
    try expectThrows(EnvironmentScrubError.targetAlreadyPresent("HCLOUD_TOKEN"), {
        _ = try EnvironmentScrubber().scrub(parent: ["HCLOUD_TOKEN": "ambient"], targetEnvironmentName: "HCLOUD_TOKEN", injectedValue: "new")
    }, "ambient target env must fail closed")

    let redacted = Redactor().redact("OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz url=https://e.test?a=1&access_token=abc")
    try expect(!redacted.contains("sk-abcdefghijklmnopqrstuvwxyz") && !redacted.contains("abc"), "redactor must remove secret corpus")
    let privateKeyText = """
    -----BEGIN PRIVATE KEY-----
    abcdefghijklmnopqrstuvwxyz
    -----END PRIVATE KEY-----
    Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456
    """
    let redactedPrivateKey = Redactor().redact(privateKeyText)
    try expect(!redactedPrivateKey.contains("BEGIN PRIVATE KEY"), "redactor must remove private key blocks")
    try expect(!redactedPrivateKey.contains("abcdefghijklmnopqrstuvwxyz123456"), "redactor must remove bearer tokens")

    let audit = AuditLog()
    let leakingEvent = AuditEvent(event: "secret_delivery", decision: "allow", flow: .cliEnv, subjectID: "s", secretID: "sec", actionClass: "hcloud.server.list", delivery: .env, policyEpoch: 1, approval: "once", time: Date(timeIntervalSince1970: 0), metadata: ["bad": "sk-abcdefghijklmnopqrstuvwxyz"])
    try expectThrows(AuditError.rawSecretDetected("pattern"), {
        try audit.append(leakingEvent)
    }, "audit must reject raw secret patterns")
    try audit.append(AuditEvent(event: "secret_delivery", decision: "allow", flow: .cliEnv, subjectID: "subject", secretID: "secret", actionClass: "hcloud.server.list", delivery: .env, policyEpoch: 1, approval: "once", time: Date(timeIntervalSince1970: 1), metadata: ["safe": "ok"]))
    try expect(audit.snapshot().count == 1, "audit must persist safe structured events")
    try expect(audit.snapshot()[0].outcome == "allow", "audit event outcome must default to decision when omitted")
    let auditExport = try audit.exportRedactedJSON()
    try expect(!auditExport.contains("super-secret-token"), "audit export must not contain resolved secret plaintext")

    let authorizer = ProxyAuthorizer()
    let (session, token) = authorizer.createSession(profile: BuiltInProxyProfiles.openAI, bindPort: 48177, token: "local-session-token", now: Date(timeIntervalSince1970: 0))
    try authorizer.authorize(session: session, token: token, method: "POST", path: "/v1/responses", now: Date(timeIntervalSince1970: 1))
    try expectThrows(ProxyError.tokenMismatch, {
        try authorizer.authorize(session: session, token: "wrong-token", method: "POST", path: "/v1/responses", now: Date(timeIntervalSince1970: 1))
    }, "proxy must reject wrong local capability token")
    try expectThrows(ProxyError.methodBlocked, {
        try authorizer.authorize(session: session, token: token, method: "DELETE", path: "/v1/responses", now: Date(timeIntervalSince1970: 1))
    }, "proxy must block disallowed HTTP methods")
    try expectThrows(ProxyError.expired, {
        try authorizer.authorize(session: session, token: token, method: "POST", path: "/v1/responses", now: Date(timeIntervalSince1970: 901))
    }, "proxy token must expire")
    try expectThrows(ProxyError.pathBlocked, {
        try authorizer.authorize(session: session, token: token, method: "POST", path: "/admin", now: Date(timeIntervalSince1970: 1))
    }, "proxy must block unknown paths")
    try expectThrows(ProxyError.crossOriginRedirectBlocked, {
        try authorizer.validateRedirect(session: session, location: URL(string: "https://evil.example.test/v1/responses")!)
    }, "proxy must block cross-origin redirects")
    let proxyRuntime = ProxyRuntime()
    let upstreamRequest = try proxyRuntime.prepareUpstreamRequest(
        session: session,
        request: ProxyHTTPRequest(method: "POST", path: "/v1/responses", headers: ["AGENTIC_FORTRESS_PROXY_TOKEN": token], body: Data("{}".utf8), sessionToken: token),
        upstreamSecret: SecretMaterial(utf8: "real-upstream-secret"),
        now: Date(timeIntervalSince1970: 1)
    )
    try expect(upstreamRequest.url.absoluteString == "https://api.openai.com/v1/responses", "proxy runtime must pin upstream origin and append allowed path")
    try expect(upstreamRequest.headers["Authorization"] == "Bearer real-upstream-secret", "proxy runtime must inject upstream authorization only in upstream request")
    try expect(upstreamRequest.headers["AGENTIC_FORTRESS_PROXY_TOKEN"] == nil, "proxy runtime must not forward local proxy capability token upstream")
    try expect(upstreamRequest.auditMetadata["authorization"] == "present-redacted", "proxy runtime audit metadata must not include upstream secret")
    try expectThrows(ProxyError.bodyLoggingDisabled, {
        _ = try proxyRuntime.bodyForAudit(Data("secret-body".utf8))
    }, "proxy runtime must not log request bodies by default")

    let bwsPolicy = BWSProviderPolicy()
    let bwsBinding = BWSSecretBinding(alias: "cloud.hcloud.dev", projectID: "cloud-dev", secretID: "sec_hcloud", environment: "dev")
    let invocation = try bwsPolicy.authorizeRuntimeRead(alias: "cloud.hcloud.dev", bindings: [bwsBinding], sinkIdentity: "agentic-fortress-shim", now: Date(timeIntervalSince1970: 0))
    try bwsPolicy.validate(invocation: invocation, sinkIdentity: "agentic-fortress-shim", now: Date(timeIntervalSince1970: 1))
    let bwsClient = InMemoryBWSSecretClient(secrets: ["sec_hcloud": SecretMaterial(utf8: "bws-secret-value")])
    let bwsRuntime = BWSProviderRuntime(client: bwsClient)
    let fetchedBWSSecret = try bwsRuntime.fetchOne(invocation: invocation, sinkIdentity: "agentic-fortress-shim", now: Date(timeIntervalSince1970: 1))
    try fetchedBWSSecret.withUTF8String { value in
        try expect(value == "bws-secret-value", "BWS runtime must fetch exactly the approved secret")
    }
    try expectThrows(BWSProviderError.invalidOperation, {
        _ = try bwsPolicy.authorizeRuntimeRead(alias: "missing.alias", bindings: [bwsBinding], sinkIdentity: "agentic-fortress-shim", now: Date(timeIntervalSince1970: 0))
    }, "BWS runtime must fetch only exact approved aliases")
    try expectThrows(BWSProviderError.expired, {
        try bwsPolicy.validate(invocation: invocation, sinkIdentity: "agentic-fortress-shim", now: Date(timeIntervalSince1970: 31))
    }, "BWS invocation must expire")
    try expectThrows(BWSProviderError.runtimeListDenied, {
        try bwsPolicy.denyListAllInRuntime()
    }, "BWS runtime list-all must be denied")
    try expectThrows(BWSProviderError.runtimeFetchProjectDenied, {
        try bwsPolicy.denyFetchProjectInRuntime()
    }, "BWS runtime fetch-project must be denied")
    try expectThrows(BWSProviderError.wrongSink, {
        try bwsPolicy.validate(invocation: invocation, sinkIdentity: "agentic-fortress-mcpd", now: Date(timeIntervalSince1970: 1))
    }, "BWS invocation must bind sink")
    try expectThrows(BWSProviderError.wrongSink, {
        _ = try bwsRuntime.fetchOne(invocation: invocation, sinkIdentity: "agentic-fortress-mcpd", now: Date(timeIntervalSince1970: 1))
    }, "BWS runtime must refuse to deliver to wrong sink")
    try expect(BWSProviderLeasePolicy.policy(for: .dev).maxLeaseSeconds == 300, "dev BWS lease policy must allow short provider lease")
    try expect(BWSProviderLeasePolicy.policy(for: .staging).maxLeaseSeconds == 60, "staging BWS lease policy must cap provider lease")
    try expect(BWSProviderLeasePolicy.policy(for: .prod).requiresPerFetchApproval, "prod BWS lease policy must require per-fetch approval")
    var rotation = BWSRotationState(binding: bwsBinding)
    for step in BWSRotationWorkflow.requiredSteps {
        rotation = try BWSRotationWorkflow.advance(rotation, completing: step)
    }
    try expect(rotation.isComplete, "BWS rotation workflow must complete after all ordered steps")
    try expectThrows(BWSProviderError.rotationOutOfOrder, {
        _ = try BWSRotationWorkflow.advance(BWSRotationState(binding: bwsBinding), completing: .storedInLocalSecretStore)
    }, "BWS rotation workflow must reject out-of-order steps")

    let mcpProfile = MCPUpstreamProfile(name: "prod-mcp", origin: URL(string: "https://mcp.example.test")!, allowedPathPrefixes: ["/mcp"])
    let mcpSession = try MCPBridgeSession(profile: mcpProfile).updatingFromResponse(headers: ["MCP-Session-Id": "sess_123"])
    try expect(mcpSession.requestHeaders(bearerToken: "token")["MCP-Session-Id"] == "sess_123", "MCP bridge must propagate session ID")
    try expectThrows(MCPBridgeError.invalidSessionID, {
        _ = try MCPBridgeSession(profile: mcpProfile).updatingFromResponse(headers: ["MCP-Session-Id": "   "])
    }, "MCP bridge must reject empty session IDs")
    try expectThrows(MCPBridgeError.pathBlocked, {
        try mcpSession.validate(path: "/other")
    }, "MCP bridge must pin allowed path prefixes")
    try expectThrows(MCPBridgeError.crossOriginRedirectBlocked, {
        try mcpSession.validate(path: "/mcp", redirect: URL(string: "https://other.example.test/mcp")!)
    }, "MCP bridge must block cross-origin redirects")
    let jsonrpcLine = try JSONRPCFramer.encodeLine(JSONRPCMessage(id: "1", method: "tools/list"))
    let decodedJSONRPC = try JSONRPCFramer.decodeLine(jsonrpcLine)
    try expect(decodedJSONRPC.method == "tools/list", "MCP JSON-RPC framer must round-trip method messages")
    try expectThrows(MCPBridgeError.invalidJSONRPC, {
        _ = try JSONRPCFramer.decodeLine("{\"jsonrpc\":\"1.0\"}")
    }, "MCP JSON-RPC framer must reject invalid messages")
    let mcpHTTPRequest = try mcpSession.prepareHTTPRequest(path: "/mcp", message: JSONRPCMessage(id: "2", method: "initialize"), bearerToken: "mcp-secret-token")
    try expect(mcpHTTPRequest.headers["Authorization"] == "Bearer mcp-secret-token", "MCP bridge must inject Authorization header")
    try expect(mcpHTTPRequest.headers["MCP-Session-Id"] == "sess_123", "MCP bridge must propagate MCP-Session-Id header")
    try expect(mcpHTTPRequest.auditMetadata["body"] == "disabled", "MCP bridge audit metadata must not include body")
    let cancellation = mcpSession.cancellationMessage(id: "2")
    try expect(cancellation.method == "notifications/cancelled", "MCP bridge must model client cancellation")
    try expect(mcpSession.responseMetadata(statusCode: 401, headers: ["WWW-Authenticate": "Bearer realm=\"mcp\""])["auth_challenge"] == "Bearer realm=\"mcp\"", "MCP bridge must preserve 401 challenge metadata")
    try expect(mcpSession.responseMetadata(statusCode: 404, headers: [:])["session_reset"] == "true", "MCP bridge must mark 404 session reset metadata")
    try expectThrows(MCPBridgeError.bodyLoggingDisabled, {
        _ = try mcpSession.bodyForAudit(Data("secret-body".utf8))
    }, "MCP bridge must not log bodies by default")

    let lease = CryptoLease(
        id: "lease_1",
        scope: LeaseScope(subject: "hcloud", adapterIdentity: hcloudRead.adapterIdentity!.leaseComponent, secretAlias: "cloud.hcloud.dev", workspaceHash: "hmac:abc", parentApp: "Codex", actionClass: "hcloud.server.list", configContext: "", deliveryMode: .env, targetIdentity: "sha256:hcloud"),
        risk: .readOnly,
        expiresAt: Date(timeIntervalSince1970: 3600),
        policyEpoch: 1
    )
    let locked = RollbackProtector().lockIfRolledBack(
        policy: PolicyState(epoch: 1, hash: "old", locked: false, rememberedLeases: [lease]),
        anchor: RollbackAnchor(latestPolicyEpoch: 2, latestPolicyHash: "new", latestAuditHead: "audit", latestAppVersion: "1.0.0")
    )
    try expect(locked.locked && locked.rememberedLeases.isEmpty, "rollback mismatch must lock policy and clear leases")

    let policyRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-policy-\(UUID().uuidString)")
    let policyURL = policyRoot.appendingPathComponent("policy.json")
    let policyRepository = FilePolicyRepository(url: policyURL, macKeyData: Data("policy-mac-key-32-bytes-long!!".utf8))
    let persistedPolicy = PolicyState(epoch: 9, hash: "policy-hash", locked: false, rememberedLeases: [lease])
    try policyRepository.save(persistedPolicy)
    let loadedPolicy = try policyRepository.load()
    try expect(loadedPolicy == persistedPolicy, "policy repository must persist and verify MACed policy state")
    var tamperedPolicyText = try String(contentsOf: policyURL, encoding: .utf8)
    tamperedPolicyText = tamperedPolicyText.replacingOccurrences(of: "\"epoch\" : 9", with: "\"epoch\" : 10")
    try tamperedPolicyText.write(to: policyURL, atomically: true, encoding: .utf8)
    try expectThrows(PolicyRepositoryError.macMismatch, {
        _ = try policyRepository.load()
    }, "policy repository must reject tampered policy database")
    let secretLikeLease = CryptoLease(
        id: "lease_secret",
        scope: LeaseScope(subject: "hcloud", adapterIdentity: "adapter", secretAlias: "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz", workspaceHash: "hmac:abc", parentApp: "Codex", actionClass: "hcloud.server.list", configContext: "", deliveryMode: .env, targetIdentity: "sha256:hcloud"),
        risk: .readOnly,
        expiresAt: Date(timeIntervalSince1970: 3600),
        policyEpoch: 1
    )
    try expectThrows(PolicyRepositoryError.plaintextSecretDetected, {
        try policyRepository.save(PolicyState(epoch: 10, hash: "secret-policy", rememberedLeases: [secretLikeLease]))
    }, "policy repository must reject plaintext secret-like policy content")
    try? FileManager.default.removeItem(at: policyRoot)

    let anchorRepo = InMemoryRollbackAnchorRepository()
    let anchor = RollbackAnchor(latestPolicyEpoch: 9, latestPolicyHash: "policy-hash", latestAuditHead: "audit-head", latestAppVersion: "0.1.0")
    try anchorRepo.saveAnchor(anchor)
    let loadedAnchor = try anchorRepo.loadAnchor()
    try expect(loadedAnchor == anchor, "rollback anchor repository must save and load anchor state")

    let recovery = try RecoveryBundleFactory.export(policy: persistedPolicy, aliasMap: ["cloud.hcloud.dev": "sec_hcloud"], providerBindingsWithoutPlaintextTokens: ["bws:project=cloud-dev;env=dev"], auditHead: "audit-head")
    try expect(recovery.epoch == persistedPolicy.epoch && recovery.policyHash == persistedPolicy.hash, "recovery bundle must preserve epoch metadata")
    try expectThrows(RecoveryBundleError.plaintextProviderTokenDetected, {
        _ = try RecoveryBundleFactory.export(policy: persistedPolicy, aliasMap: [:], providerBindingsWithoutPlaintextTokens: ["BWS_ACCESS_TOKEN=sk-abcdefghijklmnopqrstuvwxyz"], auditHead: "audit")
    }, "recovery bundle must reject plaintext provider tokens")

    let report = ReleaseGateRunner().staticReport()
    try expect(Set(report.results.map(\.gate)) == Set(ReleaseGate.allCases), "release gate report must cover all gates")
    try expect(report.canRunLocal, "release gate report must allow the production self-build track")
    try expect(report.canRelease, "legacy canRelease must map to local self-build readiness")
    try expect(!report.canDistributeBinary, "release gate report must keep optional Developer ID binary distribution separate")
    let blockedLocalGates = Set(report.results.filter { !$0.passed }.map(\.gate))
    try expect(blockedLocalGates.isEmpty, "release gate report must not block local self-build on optional Developer ID gates")
    let blockedBinaryGates = Set(report.binaryDistributionResults.filter { !$0.passed }.map(\.gate))
    try expect(blockedBinaryGates == [.macOSPackaging], "binary distribution report must isolate Developer ID packaging as optional future work")
    let forbiddenGetterFixture = "public func "
        + "getSecret(name: String) -> String"
    try expect(PublicAPITripwire.scan(source: forbiddenGetterFixture) == ["getSecret"], "API tripwire must catch forbidden raw getter")

    let config = try ConfigurationLoader.load(path: "config/default.agentic-fortress.json")
    try expect(config.adapterTrust.requireSignatureForExternalPacks, "default config must require signed external adapter packs")
    try expect(config.deliveryDefaults.denyRawEnvForGenericRunners, "default config must deny raw env for generic runners")
    try expect(config.macOSCompatibility.requiredSDKMajor == 26, "default config must target Tahoe SDK compatibility")
    let encodedConfig = try ConfigurationLoader.encode(config)
    try expect(encodedConfig.contains("\"requiredSDKMajor\" : 26"), "config encode path must preserve Tahoe SDK gate")
    let oldMacReport = MacOSCompatibility.runtimeReport(sdkMajor: 25, operatingSystemVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0))
    try expect(!oldMacReport.runtimeOK && oldMacReport.sdkOK == false, "macOS compatibility report must fail old runtime and SDK")

    let signingKey = P256.Signing.PrivateKey()
    let signedPayload = AdapterPackPayload(
        adapterID: "com.example.adapters.demo",
        adapterVersion: 2,
        cliName: "demo",
        supportedCLIVersions: ["1.*"],
        publisher: "Example Publisher",
        issuedAt: Date(timeIntervalSince1970: 0),
        expiresAt: Date(timeIntervalSince1970: 3600),
        rules: [.init(resource: "thing", verb: "list", risk: .readOnly)],
        defaultWarning: "Unknown demo command."
    )
    let pack = try signedPack(payload: signedPayload, key: signingKey)
    let verifier = AdapterPackVerifier(
        trustedPublicKeys: ["example-key": signingKey.publicKey],
        allowedPublishers: ["Example Publisher"],
        allowedCLIs: ["demo"]
    )
    let verified = try verifier.verify(pack, now: Date(timeIntervalSince1970: 1))
    try expect(verified.adapterID == signedPayload.adapterID, "signed adapter pack must verify")

    var tampered = pack
    tampered.payload.rules = [.init(resource: "thing", verb: "delete", risk: .readOnly)]
    try expectThrows(AdapterPackError.invalidSignature, {
        _ = try verifier.verify(tampered, now: Date(timeIntervalSince1970: 1))
    }, "tampered adapter pack must fail signature verification")

    try expectThrows(AdapterPackError.untrustedKey("missing-key"), {
        _ = try verifier.verify(SignedAdapterPack(payload: signedPayload, signatureBase64: pack.signatureBase64, keyID: "missing-key"), now: Date(timeIntervalSince1970: 1))
    }, "adapter verifier must reject untrusted key ids before accepting packs")

    let expiredPayload = AdapterPackPayload(
        adapterID: "com.example.adapters.expired",
        adapterVersion: 1,
        cliName: "demo",
        publisher: "Example Publisher",
        issuedAt: Date(timeIntervalSince1970: 0),
        expiresAt: Date(timeIntervalSince1970: 10),
        rules: [.init(resource: "thing", verb: "list", risk: .readOnly)],
        defaultWarning: "expired"
    )
    try expectThrows(AdapterPackError.expired, {
        _ = try verifier.verify(try signedPack(payload: expiredPayload, key: signingKey), now: Date(timeIntervalSince1970: 11))
    }, "adapter verifier must reject expired packs")

    let publisherDeniedPayload = AdapterPackPayload(
        adapterID: "com.example.adapters.badpublisher",
        adapterVersion: 1,
        cliName: "demo",
        publisher: "Untrusted Publisher",
        rules: [.init(resource: "thing", verb: "list", risk: .readOnly)],
        defaultWarning: "bad publisher"
    )
    try expectThrows(AdapterPackError.publisherNotAllowed("Untrusted Publisher"), {
        _ = try verifier.verify(try signedPack(payload: publisherDeniedPayload, key: signingKey), now: Date(timeIntervalSince1970: 1))
    }, "adapter verifier must enforce publisher allowlist")

    let cliDeniedPayload = AdapterPackPayload(
        adapterID: "com.example.adapters.badcli",
        adapterVersion: 1,
        cliName: "unexpected-cli",
        publisher: "Example Publisher",
        rules: [.init(resource: "thing", verb: "list", risk: .readOnly)],
        defaultWarning: "bad cli"
    )
    try expectThrows(AdapterPackError.cliNotAllowed("unexpected-cli"), {
        _ = try verifier.verify(try signedPack(payload: cliDeniedPayload, key: signingKey), now: Date(timeIntervalSince1970: 1))
    }, "adapter verifier must enforce CLI allowlist")

    let duplicateRulePayload = AdapterPackPayload(
        adapterID: "com.example.adapters.duplicate",
        adapterVersion: 1,
        cliName: "demo",
        publisher: "Example Publisher",
        rules: [
            .init(resource: "thing", verb: "list", risk: .readOnly),
            .init(resource: "thing", verb: "list", risk: .readOnly)
        ],
        defaultWarning: "duplicate"
    )
    try expectThrows(AdapterPackError.invalidRule("duplicate rule thing list"), {
        _ = try verifier.verify(try signedPack(payload: duplicateRulePayload, key: signingKey), now: Date(timeIntervalSince1970: 1))
    }, "adapter verifier must reject duplicate rules")

    let misleadingReadOnlyPayload = AdapterPackPayload(
        adapterID: "com.example.adapters.misleading",
        adapterVersion: 1,
        cliName: "demo",
        publisher: "Example Publisher",
        rules: [.init(resource: "thing", verb: "list", risk: .readOnly, actionClass: "demo.thing.delete")],
        defaultWarning: "misleading"
    )
    try expectThrows(AdapterPackError.invalidRule("read-only destructive-looking action class"), {
        _ = try verifier.verify(try signedPack(payload: misleadingReadOnlyPayload, key: signingKey), now: Date(timeIntervalSince1970: 1))
    }, "adapter verifier must reject destructive-looking read-only action classes")

    var customRegistry = AdapterRegistry()
    try customRegistry.installVerified(payload: signedPayload)
    let customCommand = CommandClassifier(registry: customRegistry).classify(executableName: "demo", arguments: ["thing", "list"])
    try expect(customCommand.risk == .readOnly, "custom registered adapter must classify matching command")
    try expect(customCommand.adapterIdentity?.adapterHash == AdapterCanonicalizer.hash(signedPayload), "custom adapter identity must carry canonical adapter hash")

    let registryRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-adapters-\(UUID().uuidString)")
    let registryURL = registryRoot.appendingPathComponent("adapters.json")
    let registryStore = AdapterRegistryStore(url: registryURL)
    try registryStore.install(payload: signedPayload, now: Date(timeIntervalSince1970: 1))
    let registryDocument = try registryStore.loadDocument()
    try expect(registryDocument.entries.count == 1, "adapter registry store must persist installed adapters")
    try AdapterGoldenFixtureRunner.run(
        fixtures: [AdapterGoldenFixture(executableName: "demo", arguments: ["thing", "list"], expectedRisk: .readOnly, expectedActionClass: "demo.thing.list")],
        registry: try registryStore.activeRegistry()
    )
    try expectThrows(AdapterGoldenFixtureError.mismatch(expected: AdapterGoldenFixture(executableName: "demo", arguments: ["thing", "list"], expectedRisk: .destructive, expectedActionClass: "demo.thing.delete"), actualRisk: .readOnly, actualActionClass: "demo.thing.list"), {
        try AdapterGoldenFixtureRunner.run(
            fixtures: [AdapterGoldenFixture(executableName: "demo", arguments: ["thing", "list"], expectedRisk: .destructive, expectedActionClass: "demo.thing.delete")],
            registry: try registryStore.activeRegistry()
        )
    }, "adapter golden fixtures must fail closed on classification mismatch")
    let firstHash = CommandClassifier(registry: try registryStore.activeRegistry()).classify(executableName: "demo", arguments: ["thing", "list"]).adapterIdentity?.adapterHash
    let changedPayload = AdapterPackPayload(
        adapterID: "com.example.adapters.demo",
        adapterVersion: 3,
        cliName: "demo",
        publisher: "Example Publisher",
        rules: [.init(resource: "thing", verb: "list", risk: .readOnly, warnings: ["changed"])],
        defaultWarning: "changed"
    )
    try registryStore.install(payload: changedPayload, now: Date(timeIntervalSince1970: 2))
    let changedHash = CommandClassifier(registry: try registryStore.activeRegistry()).classify(executableName: "demo", arguments: ["thing", "list"]).adapterIdentity?.adapterHash
    try expect(firstHash != changedHash, "adapter hash changes must invalidate lease identity")
    try registryStore.revoke(adapterID: "com.example.adapters.demo", now: Date(timeIntervalSince1970: 3))
    let revokedCommand = CommandClassifier(registry: try registryStore.activeRegistry()).classify(executableName: "demo", arguments: ["thing", "list"])
    try expect(revokedCommand.risk == .unknown, "revoked adapter must not remain active")
    try? FileManager.default.removeItem(at: registryRoot)

    var registry = AdapterRegistry()
    try registry.installVerified(payload: signedPayload)
    let olderPayload = AdapterPackPayload(
        adapterID: "com.example.adapters.demo",
        adapterVersion: 1,
        cliName: "demo",
        publisher: "Example Publisher",
        rules: [.init(resource: "thing", verb: "list", risk: .readOnly)],
        defaultWarning: "older"
    )
    try expectThrows(AdapterPackError.rollback(adapterID: "com.example.adapters.demo", currentVersion: 2, incomingVersion: 1), {
        try registry.installVerified(payload: olderPayload)
    }, "adapter registry must reject adapter rollback")

    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentic-fortress-target-\(UUID().uuidString)")
    let targetFile = tempRoot.appendingPathComponent("tool")
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "hello".data(using: .utf8)!.write(to: targetFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempRoot.path)
    let targetAssessment = try TargetAssessor().assess(path: targetFile.path)
    try expect(targetAssessment.identity.hasPrefix("sha256:"), "target assessor must hash assessed binaries")
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: tempRoot.path)
    try expectThrows(TargetAssessmentError.worldWritableParent(tempRoot.path), {
        _ = try TargetAssessor().assess(path: targetFile.path)
    }, "target assessor must reject world-writable parent directories")
    try? FileManager.default.removeItem(at: tempRoot)
}

do {
    try runContracts()
    print("AgenticFortress contract tests passed")
} catch {
    fputs("AgenticFortress contract tests failed: \(error)\n", stderr)
    exit(1)
}
