import AgenticFortressCore
import CryptoKit
import Foundation

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

    let bwsPolicy = BWSProviderPolicy()
    let bwsBinding = BWSSecretBinding(alias: "cloud.hcloud.dev", projectID: "cloud-dev", secretID: "sec_hcloud", environment: "dev")
    let invocation = try bwsPolicy.authorizeRuntimeRead(alias: "cloud.hcloud.dev", bindings: [bwsBinding], sinkIdentity: "agentic-fortress-shim", now: Date(timeIntervalSince1970: 0))
    try bwsPolicy.validate(invocation: invocation, sinkIdentity: "agentic-fortress-shim", now: Date(timeIntervalSince1970: 1))
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
