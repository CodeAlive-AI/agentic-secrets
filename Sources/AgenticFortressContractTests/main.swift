import AgenticFortressCore
import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct ContractTestFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
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

    let destructive = classifier.classify(executableName: "hcloud", arguments: ["server", "delete", "prod-db-01"], observedVersion: "1.52.0")
    let destructiveManifest = DecisionManifestFactory().make(
        command: destructive,
        intent: DeliveryIntent(flow: .cliEnv, secretAlias: "cloud.hcloud.dev", delivery: .env, environmentName: "HCLOUD_TOKEN", workspace: "/tmp/infra", parentApp: "Codex"),
        target: TargetAssessor().synthetic(path: "/opt/homebrew/bin/hcloud")
    )
    try expect(destructiveManifest.approvalOptions == [.deny], "destructive actions must not offer remembered approval")
    try expect(destructiveManifest.typedChallenge == destructiveManifest.digest, "destructive manifest must expose typed challenge digest")

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
    let authReason = LocalAuthenticationGate.reason(for: approvalManifest)
    try expect(authReason.contains(approvalManifest.digest), "LocalAuthentication reason must include manifest digest")
    let authProof = LocalAuthenticationProof(manifestDigest: approvalManifest.digest, actionClass: approvalManifest.actionClass, reason: authReason, authenticatedAt: Date(timeIntervalSince1970: 0))
    try LocalAuthenticationGate.validate(proof: authProof, manifest: approvalManifest, now: Date(timeIntervalSince1970: 10))
    try expectThrows(LocalAuthenticationError.staleProof, {
        try LocalAuthenticationGate.validate(proof: authProof, manifest: approvalManifest, now: Date(timeIntervalSince1970: 31))
    }, "LocalAuthentication proof must expire quickly")
    try expectThrows(LocalAuthenticationError.digestMismatch, {
        try LocalAuthenticationGate.validate(proof: LocalAuthenticationProof(manifestDigest: "wrong", actionClass: approvalManifest.actionClass, reason: authReason, authenticatedAt: Date(timeIntervalSince1970: 0)), manifest: approvalManifest, now: Date(timeIntervalSince1970: 1))
    }, "LocalAuthentication proof must bind manifest digest")

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
    try expect(keychainAddQuery[kSecUseDataProtectionKeychain] as? Bool == true, "Keychain add query must use data-protection keychain")
    try expect(keychainAddQuery[kSecAttrAccessControl] != nil, "Keychain add query must use access control when user presence is required")
    try expect(KeychainSecretQueryFactory.accessControlFlags(for: .presenceRequired).contains(.userPresence), "presence-required Keychain policy must require user presence")
    try expect(KeychainSecretQueryFactory.accessControlFlags(for: .biometryCurrent).contains(.biometryCurrentSet), "biometry-current Keychain policy must bind current biometric set")
    let keychainContext = LAContext()
    keychainContext.localizedReason = LocalAuthenticationGate.reason(for: approvalManifest)
    let keychainReadQuery = KeychainSecretQueryFactory.readQuery(descriptor: keychainDescriptor, context: keychainContext)
    try expect(keychainReadQuery[kSecUseAuthenticationContext] != nil, "Keychain read query must carry LAContext for approval prompt reason")
    let keychainBinding = try KeychainSecretStore(service: "com.agenticfortress.test").binding(for: secretAlias)
    try expect(keychainBinding.storeKind == "keychain", "Keychain secret store must expose keychain binding metadata without plaintext")

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
    let execPlan = try ShimExecutionPlanner().plan(
        request: shimRequest,
        targetPolicies: [shimPolicy],
        policyState: PolicyState(epoch: 1),
        approvalSessionID: shimApproval.id,
        approvalSessions: shimApprovals,
        secrets: secretStore,
        handles: shimHandles,
        now: Date(timeIntervalSince1970: 1)
    )
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
        request: ProxyHTTPRequest(method: "POST", path: "/v1/responses", headers: ["KEYGATE_PROXY_TOKEN": token], body: Data("{}".utf8), sessionToken: token),
        upstreamSecret: SecretMaterial(utf8: "real-upstream-secret"),
        now: Date(timeIntervalSince1970: 1)
    )
    try expect(upstreamRequest.url.absoluteString == "https://api.openai.com/v1/responses", "proxy runtime must pin upstream origin and append allowed path")
    try expect(upstreamRequest.headers["Authorization"] == "Bearer real-upstream-secret", "proxy runtime must inject upstream authorization only in upstream request")
    try expect(upstreamRequest.headers["KEYGATE_PROXY_TOKEN"] == nil, "proxy runtime must not forward local proxy capability token upstream")
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
        _ = try BWSRotationWorkflow.advance(BWSRotationState(binding: bwsBinding), completing: .storedInKeychain)
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
    try expect(report.canRelease, "release gate report must pass")
    try expect(PublicAPITripwire.scan(source: "public func getSecret(name: String) -> String") == ["getSecret"], "public API tripwire must catch getSecret")

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
