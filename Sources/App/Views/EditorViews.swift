import AgenticFortressCore
import SwiftUI

struct RegisterCLIView: View {
    @Bindable var store: ManagementStore
    @Environment(\.dismiss) private var dismiss
    @State private var step: RegisterCLIStep = .target
    @State private var name = ""
    @State private var targetPath = ""
    @State private var bindings = [SecretDraft()]
    @State private var installShim = RegisterCLIFormDefaults.installShim
    @State private var reviewAdvancedExpanded = false

    var canSubmit: Bool {
        RegisterCLIFormValidation.canSubmit(name: name, targetPath: targetPath, bindings: bindings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RegisterCLIStepHeader(step: step)
            Form { stepContent }
            SheetFeedbackBanner(store: store)
            HStack {
                if step != .target {
                    Button("Back") { step = step.previous }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if step == .review {
                    Button("Register") {
                        let secrets = RegisterCLIFormValidation.environmentSecrets(bindings)
                        Task {
                            if await store.registerCLI(name: name, targetPath: targetPath, environmentSecrets: secrets, installShim: installShim) {
                                dismiss()
                            }
                        }
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                } else {
                    Button("Next") {
                        step = step.next
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                }
            }
            .padding()
        }
        .frame(width: 600)
        .padding()
        .onAppear {
            store.clearFeedback()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .target:
            Section("Target") {
                TextField("CLI name", text: $name, prompt: Text("hcloud"))
                    .accessibilityLabel("CLI name")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("Executable path", text: $targetPath, prompt: Text("/opt/homebrew/bin/hcloud"))
                        .accessibilityLabel("Executable path")
                    Button {
                        chooseExecutable()
                    } label: {
                        Label("Choose...", systemImage: "folder")
                    }
                    .help("Choose the CLI executable from disk")
                }
                if let message = ExecutablePathSelection.statusMessage(for: targetPath) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Use the resolved executable path for the CLI you want Agentic Fortress to verify before delivery.")
                    .foregroundStyle(.secondary)
            }
        case .bindings:
            Section("Environment bindings") {
                ForEach($bindings) { $binding in
                    HStack {
                        TextField("ENV_NAME", text: $binding.environmentName)
                            .accessibilityLabel("Environment variable name")
                        Button {
                            bindings.removeAll { $0.id == binding.id }
                            if bindings.isEmpty { bindings.append(SecretDraft()) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove binding")
                        .accessibilityLabel("Remove environment binding")
                    }
                }
                Button {
                    bindings.append(SecretDraft())
                } label: {
                    Label("Add Environment Binding", systemImage: "plus")
                }
                if RegisterCLIFormValidation.hasDuplicateEnvironmentNames(bindings) {
                    Text("Environment names must be unique.")
                        .foregroundStyle(.red)
                }
                if !RegisterCLIFormValidation.invalidEnvironmentNames(bindings).isEmpty {
                    Text("Use shell-style names such as HCLOUD_TOKEN: letters, numbers, and underscores; do not start with a number.")
                        .foregroundStyle(.red)
                }
            }
        case .secrets:
            Section("Write-only secrets") {
                ForEach($bindings) { $binding in
                    SecureField(binding.environmentName.isEmpty ? "Secret value" : binding.environmentName, text: $binding.secretValue)
                        .accessibilityLabel("Secret value for \(binding.environmentName.isEmpty ? "environment binding" : binding.environmentName)")
                }
                if bindings.contains(where: { !$0.secretValue.isEmpty && !SecretInputValidation.hasNonWhitespace($0.secretValue) }) {
                    Text("Secret values cannot be only whitespace.")
                        .foregroundStyle(.red)
                }
                Text("Values are written once through core-owned local state. Saved values are never displayed in the UI.")
                    .foregroundStyle(.secondary)
            }
        case .review:
            Section("Trust review") {
                LabeledContent("CLI name", value: name.trimmingCharacters(in: .whitespacesAndNewlines))
                LabeledContent("Executable", value: targetPath.trimmingCharacters(in: .whitespacesAndNewlines))
                LabeledContent("Environment bindings", value: bindings.map(\.environmentName).filter { !$0.isEmpty }.joined(separator: ", "))
                LabeledContent("Command shim", value: installShim ? "Install by default" : "Skip")
                Text("Registration stores only aliases and target trust metadata in management responses. Secret values remain write-only.")
                    .foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $reviewAdvancedExpanded) {
                    Toggle("Install command shim", isOn: $installShim)
                        .help("Create a local shim named like this CLI so normal invocations can route through Agentic Fortress.")
                    Text("The shim is installed in the local Agentic Fortress shims folder. Shell PATH configuration remains a separate explicit install action.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .target:
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && RegisterCLIFormValidation.isValidExecutablePath(targetPath)
        case .bindings:
            bindings.contains { !$0.environmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && !RegisterCLIFormValidation.hasDuplicateEnvironmentNames(bindings)
                && RegisterCLIFormValidation.invalidEnvironmentNames(bindings).isEmpty
        case .secrets:
            bindings.allSatisfy {
                !$0.environmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && RegisterCLIFormValidation.isValidEnvironmentName($0.environmentName)
                    && !$0.secretValue.isEmpty
                    && SecretInputValidation.hasNonWhitespace($0.secretValue)
            }
        case .review:
            canSubmit
        }
    }

    private func chooseExecutable() {
        guard let url = ExecutablePathChooser.chooseExecutable() else { return }
        targetPath = url.path
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = ExecutablePathSelection.inferredCLIName(from: url)
        }
    }
}

enum RegisterCLIFormDefaults {
    static let installShim = true
}

enum ProxyProfileEditorDefaults {
    static let origin = "https://api.openai.com"
    static let pathPrefixes = "/v1/"
    static let methods = "GET, POST"
    static let tokenTTL: Double = 900.0
}

enum MCPProfileEditorDefaults {
    static let origin = "https://mcp.example.com"
    static let authorizationHeader = "Authorization"
    static let pathPrefixes = "/"
    static let allowCrossOriginRedirects = false
}

enum BWSBindingEditorDefaults {
    static let environment = ProviderEnvironment.dev.rawValue
}

private enum RegisterCLIStep: Int, CaseIterable {
    case target
    case bindings
    case secrets
    case review

    var title: String {
        switch self {
        case .target: "Target"
        case .bindings: "Bindings"
        case .secrets: "Secrets"
        case .review: "Review"
        }
    }

    var subtitle: String {
        switch self {
        case .target: "Choose the CLI executable to verify."
        case .bindings: "Name the environment variables Agentic Fortress may deliver."
        case .secrets: "Enter secret material once; it will not be shown again."
        case .review: "Confirm the target and write-only bindings."
        }
    }

    var next: RegisterCLIStep {
        RegisterCLIStep(rawValue: rawValue + 1) ?? .review
    }

    var previous: RegisterCLIStep {
        RegisterCLIStep(rawValue: rawValue - 1) ?? .target
    }
}

private struct RegisterCLIStepHeader: View {
    var step: RegisterCLIStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Register CLI")
                .font(.title2.bold())
            Text(step.subtitle)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(RegisterCLIStep.allCases, id: \.self) { item in
                    Label(item.title, systemImage: item.rawValue <= step.rawValue ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(item == step ? .primary : .secondary)
                }
            }
        }
        .padding(.horizontal)
    }
}

struct ReplaceSecretView: View {
    @Bindable var store: ManagementStore
    @Environment(\.dismiss) private var dismiss
    var alias: String
    var label: String
    var environment: String
    @State private var value = ""

    var body: some View {
        VStack(alignment: .trailing) {
            Form {
                Section("Replace Secret") {
                    LabeledContent("Alias", value: alias)
                    SecureField("New value", text: $value)
                    Text("The existing value cannot be displayed. This writes a replacement and clears the field.")
                        .foregroundStyle(.secondary)
                }
            }
            SheetFeedbackBanner(store: store)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Replace") {
                    Task {
                        if await store.replaceSecret(alias: alias, value: value, label: label, environment: environment) {
                            value = ""
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!SecretInputValidation.hasNonWhitespace(value))
            }
            .padding()
        }
        .frame(width: 480)
        .padding()
        .onAppear {
            store.clearFeedback()
        }
    }
}

struct ProxyProfileEditor: View {
    @Bindable var store: ManagementStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var origin: String
    @State private var prefixes: String
    @State private var methods: String
    @State private var secretAlias: String
    @State private var ttl: Double
    @State private var advancedExpanded: Bool

    init(store: ManagementStore, profile: ProxyProfileSummary? = nil) {
        self.store = store
        _name = State(initialValue: profile?.name ?? "")
        _origin = State(initialValue: profile?.upstreamOrigin.absoluteString ?? ProxyProfileEditorDefaults.origin)
        _prefixes = State(initialValue: profile?.allowedPathPrefixes.joined(separator: ", ") ?? ProxyProfileEditorDefaults.pathPrefixes)
        _methods = State(initialValue: profile?.allowedMethods.joined(separator: ", ") ?? ProxyProfileEditorDefaults.methods)
        _secretAlias = State(initialValue: profile?.secretAlias ?? "")
        _ttl = State(initialValue: profile?.tokenTTLSeconds ?? ProxyProfileEditorDefaults.tokenTTL)
        _advancedExpanded = State(initialValue: profile != nil)
    }

    var body: some View {
        Form {
            Section("Proxy Profile") {
                TextField("Name", text: $name)
                TextField("Upstream origin", text: $origin)
                if let originMessage = ManagementEditorValidation.urlStatusMessage(origin, field: "upstream origin") {
                    InlineValidationMessage(originMessage)
                }
                TextField("Secret alias", text: $secretAlias)
                Text("Uses /v1/, GET and POST, and a 900s session TTL unless changed in Advanced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    TextField("Allowed path prefixes", text: $prefixes)
                    if let prefixesMessage = ManagementEditorValidation.pathPrefixStatusMessage(prefixes) {
                        InlineValidationMessage(prefixesMessage)
                    }
                    TextField("Allowed methods", text: $methods)
                    if let methodsMessage = ManagementEditorValidation.httpMethodsStatusMessage(methods) {
                        InlineValidationMessage(methodsMessage)
                    }
                    Stepper("Token TTL: \(Int(ttl))s", value: $ttl, in: 30...3600, step: 30)
                }
            }
            SheetFeedbackBanner(store: store)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        if await store.upsertProxy(name: name, origin: origin, pathPrefixes: prefixes, methods: methods, secretAlias: secretAlias, ttl: ttl) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ManagementEditorValidation.canSaveProxy(
                    name: name,
                    origin: origin,
                    pathPrefixes: prefixes,
                    methods: methods,
                    secretAlias: secretAlias
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear {
            store.clearFeedback()
        }
    }
}

struct MCPProfileEditor: View {
    @Bindable var store: ManagementStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var origin: String
    @State private var header: String
    @State private var prefixes: String
    @State private var allowRedirects: Bool
    @State private var advancedExpanded: Bool

    init(store: ManagementStore, profile: MCPProfileSummary? = nil) {
        self.store = store
        _name = State(initialValue: profile?.name ?? "")
        _origin = State(initialValue: profile?.origin.absoluteString ?? MCPProfileEditorDefaults.origin)
        _header = State(initialValue: profile?.authorizationHeaderName ?? MCPProfileEditorDefaults.authorizationHeader)
        _prefixes = State(initialValue: profile?.allowedPathPrefixes.joined(separator: ", ") ?? MCPProfileEditorDefaults.pathPrefixes)
        _allowRedirects = State(initialValue: profile?.allowCrossOriginRedirects ?? MCPProfileEditorDefaults.allowCrossOriginRedirects)
        _advancedExpanded = State(initialValue: profile != nil)
    }

    var body: some View {
        Form {
            Section("MCP Profile") {
                TextField("Name", text: $name)
                TextField("Origin", text: $origin)
                if let originMessage = ManagementEditorValidation.urlStatusMessage(origin, field: "origin") {
                    InlineValidationMessage(originMessage)
                }
                Text("Uses the Authorization header, / path prefix, and blocks cross-origin redirects unless changed in Advanced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    TextField("Authorization header", text: $header)
                    TextField("Allowed path prefixes", text: $prefixes)
                    if let prefixesMessage = ManagementEditorValidation.pathPrefixStatusMessage(prefixes) {
                        InlineValidationMessage(prefixesMessage)
                    }
                    Toggle("Allow cross-origin redirects", isOn: $allowRedirects)
                }
            }
            SheetFeedbackBanner(store: store)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        if await store.upsertMCP(name: name, origin: origin, header: header, pathPrefixes: prefixes, allowRedirects: allowRedirects) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ManagementEditorValidation.canSaveMCP(
                    name: name,
                    origin: origin,
                    header: header,
                    pathPrefixes: prefixes
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear {
            store.clearFeedback()
        }
    }
}

struct BWSBindingEditor: View {
    @Bindable var store: ManagementStore
    @Environment(\.dismiss) private var dismiss
    @State private var alias: String
    @State private var projectID: String
    @State private var secretID: String
    @State private var environment: String
    @State private var advancedExpanded: Bool

    init(store: ManagementStore, binding: BWSBindingSummary? = nil) {
        self.store = store
        _alias = State(initialValue: binding?.alias ?? "")
        _projectID = State(initialValue: binding?.projectID ?? "")
        _secretID = State(initialValue: "")
        _environment = State(initialValue: binding?.environment ?? BWSBindingEditorDefaults.environment)
        _advancedExpanded = State(initialValue: binding != nil)
    }

    var body: some View {
        Form {
            Section("BWS Binding") {
                TextField("Alias", text: $alias, prompt: Text("cloud.hcloud.dev"))
                    .accessibilityLabel("BWS binding alias")
                TextField("Project ID", text: $projectID)
                    .accessibilityLabel("BWS project ID")
                SecureField(secretPlaceholder, text: $secretID)
                    .accessibilityLabel("BWS secret ID")
                Text("Creates a development binding by default. Change the environment in Advanced when this binding is for staging or production.")
                    .foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    Picker("Environment", selection: $environment) {
                        Text("Development").tag(ProviderEnvironment.dev.rawValue)
                        Text("Staging").tag(ProviderEnvironment.staging.rawValue)
                        Text("Production").tag(ProviderEnvironment.prod.rawValue)
                    }
                    Text("Secret IDs are written to core-owned configuration and shown later only as a digest. Secret values are never fetched or displayed here.")
                        .foregroundStyle(.secondary)
                }
            }
            SheetFeedbackBanner(store: store)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        if await store.upsertBWSBinding(
                            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
                            projectID: projectID.trimmingCharacters(in: .whitespacesAndNewlines),
                            secretID: secretID.trimmingCharacters(in: .whitespacesAndNewlines),
                            environment: environment
                        ) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear {
            store.clearFeedback()
        }
    }

    private var canSave: Bool {
        !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ProviderEnvironment(rawValue: environment) != nil
    }

    private var secretPlaceholder: String {
        "BWS secret ID"
    }
}

private struct SheetFeedbackBanner: View {
    @Bindable var store: ManagementStore

    var body: some View {
        if let message = store.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    store.clearFeedback()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss error message")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        }
    }
}

private struct InlineValidationMessage: View {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

struct CopyableSecretOnceView: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
                CopyButton(value: value, help: "Copy \(title)")
            }
            Text("Shown once in this UI state. Audit and state keep only token hashes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SecretDraft: Identifiable {
    var id = UUID()
    var environmentName = ""
    var secretValue = ""
}

enum RegisterCLIFormValidation {
    static func canSubmit(name: String, targetPath: String, bindings: [SecretDraft]) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isValidExecutablePath(targetPath)
            && !bindings.isEmpty
            && bindings.allSatisfy { draft in
                !draft.environmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && isValidEnvironmentName(draft.environmentName)
                    && !draft.secretValue.isEmpty
                    && SecretInputValidation.hasNonWhitespace(draft.secretValue)
            }
            && !hasDuplicateEnvironmentNames(bindings)
    }

    static func hasDuplicateEnvironmentNames(_ bindings: [SecretDraft]) -> Bool {
        var seen = Set<String>()
        for name in bindings.map({ normalizedEnvironmentName($0.environmentName) }) where !name.isEmpty {
            if !seen.insert(name).inserted {
                return true
            }
        }
        return false
    }

    static func environmentSecrets(_ bindings: [SecretDraft]) -> [String: String] {
        var result: [String: String] = [:]
        for binding in bindings {
            let name = binding.environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidEnvironmentName(name) else { continue }
            guard SecretInputValidation.hasNonWhitespace(binding.secretValue) else { continue }
            result[name] = binding.secretValue
        }
        return result
    }

    static func invalidEnvironmentNames(_ bindings: [SecretDraft]) -> [String] {
        bindings
            .map { $0.environmentName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isValidEnvironmentName($0) }
    }

    static func isValidExecutablePath(_ value: String) -> Bool {
        ExecutablePathSelection.statusMessage(for: value) == nil
    }

    static func isValidEnvironmentName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = name.unicodeScalars.first else { return false }
        guard isEnvironmentNameStart(first) else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy(isEnvironmentNameBody)
    }

    private static func normalizedEnvironmentName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isEnvironmentNameStart(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || isASCIIAlpha(scalar)
    }

    private static func isEnvironmentNameBody(_ scalar: UnicodeScalar) -> Bool {
        isEnvironmentNameStart(scalar) || isASCIIDigit(scalar)
    }

    private static func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(Int(scalar.value))
    }
}

enum SecretInputValidation {
    static func hasNonWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

enum ManagementEditorValidation {
    static func canSaveProxy(name: String, origin: String, pathPrefixes: String, methods: String, secretAlias: String) -> Bool {
        !trimmed(name).isEmpty
            && urlStatusMessage(origin, field: "upstream origin") == nil
            && !trimmed(secretAlias).isEmpty
            && pathPrefixStatusMessage(pathPrefixes) == nil
            && httpMethodsStatusMessage(methods) == nil
    }

    static func canSaveMCP(name: String, origin: String, header: String, pathPrefixes: String) -> Bool {
        !trimmed(name).isEmpty
            && urlStatusMessage(origin, field: "origin") == nil
            && !trimmed(header).isEmpty
            && pathPrefixStatusMessage(pathPrefixes) == nil
    }

    static func urlStatusMessage(_ value: String, field: String) -> String? {
        let raw = trimmed(value)
        guard !raw.isEmpty else { return "Enter \(field)." }
        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return "Enter a valid http or https URL for \(field)."
        }
        return nil
    }

    static func listStatusMessage(_ value: String, field: String) -> String? {
        commaList(value).isEmpty ? "Enter at least one \(field)." : nil
    }

    static func pathPrefixStatusMessage(_ value: String) -> String? {
        let prefixes = commaList(value)
        guard !prefixes.isEmpty else { return "Enter at least one allowed path prefix." }
        guard prefixes.allSatisfy({ $0.hasPrefix("/") }) else {
            return "Path prefixes must start with /."
        }
        return nil
    }

    static func httpMethodsStatusMessage(_ value: String) -> String? {
        let methods = commaList(value)
        guard !methods.isEmpty else { return "Enter at least one allowed method." }
        guard methods.allSatisfy(isHTTPMethodToken) else {
            return "Use comma-separated HTTP methods such as GET, POST, PATCH."
        }
        return nil
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commaList(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isHTTPMethodToken(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
    }
}
