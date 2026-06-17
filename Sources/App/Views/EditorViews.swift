import SwiftUI

struct RegisterCLIView: View {
    @Bindable var store: ManagementStore
    @Environment(\.dismiss) private var dismiss
    @State private var step: RegisterCLIStep = .target
    @State private var name = ""
    @State private var targetPath = ""
    @State private var bindings = [SecretDraft()]

    var canSubmit: Bool {
        RegisterCLIFormValidation.canSubmit(name: name, targetPath: targetPath, bindings: bindings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RegisterCLIStepHeader(step: step)
            Form { stepContent }
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
                            await store.registerCLI(name: name, targetPath: targetPath, environmentSecrets: secrets)
                            dismiss()
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
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .target:
            Section("Target") {
                TextField("CLI name", text: $name, prompt: Text("hcloud"))
                    .accessibilityLabel("CLI name")
                TextField("Executable path", text: $targetPath, prompt: Text("/opt/homebrew/bin/hcloud"))
                    .accessibilityLabel("Executable path")
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
            }
        case .secrets:
            Section("Write-only secrets") {
                ForEach($bindings) { $binding in
                    SecureField(binding.environmentName.isEmpty ? "Secret value" : binding.environmentName, text: $binding.secretValue)
                        .accessibilityLabel("Secret value for \(binding.environmentName.isEmpty ? "environment binding" : binding.environmentName)")
                }
                Text("Values are written once through core-owned local state. Saved values are never displayed in the UI.")
                    .foregroundStyle(.secondary)
            }
        case .review:
            Section("Trust review") {
                LabeledContent("CLI name", value: name.trimmingCharacters(in: .whitespacesAndNewlines))
                LabeledContent("Executable", value: targetPath.trimmingCharacters(in: .whitespacesAndNewlines))
                LabeledContent("Environment bindings", value: bindings.map(\.environmentName).filter { !$0.isEmpty }.joined(separator: ", "))
                Text("Registration stores only aliases and target trust metadata in management responses. Secret values remain write-only.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .target:
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .bindings:
            bindings.contains { !$0.environmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && !RegisterCLIFormValidation.hasDuplicateEnvironmentNames(bindings)
        case .secrets:
            bindings.allSatisfy {
                !$0.environmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.secretValue.isEmpty
            }
        case .review:
            canSubmit
        }
    }
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
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Replace") {
                    Task {
                        await store.replaceSecret(alias: alias, value: value, label: label, environment: environment)
                        value = ""
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
        .padding()
    }
}

struct ProxyProfileEditor: View {
    @Bindable var store: ManagementStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var origin = "https://api.openai.com"
    @State private var prefixes = "/v1/"
    @State private var methods = "GET, POST"
    @State private var secretAlias = ""
    @State private var ttl = 900.0

    var body: some View {
        Form {
            Section("Proxy Profile") {
                TextField("Name", text: $name)
                TextField("Upstream origin", text: $origin)
                TextField("Allowed path prefixes", text: $prefixes)
                TextField("Allowed methods", text: $methods)
                TextField("Secret alias", text: $secretAlias)
                Stepper("Token TTL: \(Int(ttl))s", value: $ttl, in: 30...3600, step: 30)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        await store.upsertProxy(name: name, origin: origin, pathPrefixes: prefixes, methods: methods, secretAlias: secretAlias, ttl: ttl)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || origin.isEmpty || secretAlias.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}

struct MCPProfileEditor: View {
    @Bindable var store: ManagementStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var origin = "https://mcp.example.com"
    @State private var header = "Authorization"
    @State private var prefixes = "/"
    @State private var allowRedirects = false

    var body: some View {
        Form {
            Section("MCP Profile") {
                TextField("Name", text: $name)
                TextField("Origin", text: $origin)
                TextField("Authorization header", text: $header)
                TextField("Allowed path prefixes", text: $prefixes)
                Toggle("Allow cross-origin redirects", isOn: $allowRedirects)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        await store.upsertMCP(name: name, origin: origin, header: header, pathPrefixes: prefixes, allowRedirects: allowRedirects)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || origin.isEmpty || header.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
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
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
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
            && !bindings.isEmpty
            && bindings.allSatisfy { draft in
                !draft.environmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !draft.secretValue.isEmpty
            }
            && !hasDuplicateEnvironmentNames(bindings)
    }

    static func hasDuplicateEnvironmentNames(_ bindings: [SecretDraft]) -> Bool {
        var seen = Set<String>()
        for name in bindings.map({ $0.environmentName.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
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
            guard !name.isEmpty else { continue }
            result[name] = binding.secretValue
        }
        return result
    }
}
