import AgenticSecretsBroker
import SwiftUI

struct CommandPolicySettingsPage: View {
    @Binding var terms: [CommandPolicyTermDraft]
    @Binding var authorizationMode: DeliveryAuthorizationMode
    @Binding var previewCommand: String
    var hasChanges: Bool
    var canSave: Bool
    var isLoading: Bool
    var saveHelp: String
    var revert: () -> Void
    var save: () -> Void
    var cancel: (() -> Void)? = nil

    @State private var newTerm = ""
    @State private var newDisposition: CommandPolicyDisposition = .destructive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    systemImage: "shield.lefthalf.filled",
                    title: "CLI Delivery",
                    subtitle: "Choose when CLI secret delivery can reuse an approval, then define the command words that always ask or never deliver."
                )

                CLIDeliveryModePanel(mode: $authorizationMode)

                CommandPolicySummaryPanel(
                    askCount: destructiveTerms.count,
                    blockCount: forbiddenTerms.count,
                    hasChanges: hasChanges,
                    restoreDefaults: restoreDefaults
                )

                CommandPolicyAddRulePanel(
                    text: $newTerm,
                    disposition: $newDisposition,
                    existingTerms: allTerms,
                    add: addTerm
                )

                CommandPolicyTwoColumnRulesPanel(
                    terms: terms,
                    move: moveTerm,
                    remove: removeTerm
                )

                CommandPolicyPreviewPanel(
                    command: $previewCommand,
                    destructiveTerms: destructiveTerms,
                    forbiddenTerms: forbiddenTerms
                )

                CommandPolicyNotes()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .padding(.bottom, 72)
        }
        .safeAreaInset(edge: .bottom) {
            CommandPolicyActionBar(
                hasChanges: hasChanges,
                canSave: canSave,
                isLoading: isLoading,
                saveHelp: saveHelp,
                revert: revert,
                save: save,
                cancel: cancel
            )
        }
    }

    private var destructiveTerms: [String] {
        CommandPolicyTermDraft.destructiveTerms(from: terms)
    }

    private var forbiddenTerms: [String] {
        CommandPolicyTermDraft.forbiddenTerms(from: terms)
    }

    private var allTerms: [String] {
        terms.map(\.term)
    }

    private func restoreDefaults() {
        terms = CommandPolicyTermDraft.from(
            destructiveTerms: CommandPolicyConfig.default.destructiveTerms,
            forbiddenTerms: CommandPolicyConfig.default.forbiddenTerms
        )
        newTerm = ""
        newDisposition = .destructive
    }

    private func addTerm(_ value: String, disposition: CommandPolicyDisposition) -> Bool {
        let term = CommandPolicyTermValidator.normalized(value)
        guard CommandPolicyTermValidator.validate(term, existing: terms.map(\.term)) == .valid else {
            return false
        }
        terms.append(CommandPolicyTermDraft(term: term, disposition: disposition))
        terms.sort()
        return true
    }

    private func removeTerm(_ term: String) {
        terms.removeAll { $0.term == term }
    }

    private func moveTerm(_ term: String, to disposition: CommandPolicyDisposition) {
        guard let index = terms.firstIndex(where: { $0.term == term }) else { return }
        terms[index].disposition = disposition
        terms.sort()
    }
}

private struct CLIDeliveryModePanel: View {
    @Binding var mode: DeliveryAuthorizationMode

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Default approval behavior")
                        .font(.headline)
                    Text("Used when a CLI run does not pass `--authorization-mode`. Destructive and blocked rules still override this choice.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(CLIDeliveryAuthorizationChoice.allCases) { choice in
                            CLIDeliveryModeCard(choice: choice, isSelected: mode == choice.mode) {
                                mode = choice.mode
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        ForEach(CLIDeliveryAuthorizationChoice.allCases) { choice in
                            CLIDeliveryModeCard(choice: choice, isSelected: mode == choice.mode) {
                                mode = choice.mode
                            }
                        }
                    }
                }

                Text("Temporary `short` grants remain available from the CLI for one-off automation and expire after \(Int(DeliveryGrantPolicy.defaultTTL)) seconds by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

private struct CLIDeliveryModeCard: View {
    var choice: CLIDeliveryAuthorizationChoice
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : choice.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : choice.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(choice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .help(choice.detail)
    }
}

private struct SettingsHeader: View {
    var systemImage: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CommandPolicySummaryPanel: View {
    var askCount: Int
    var blockCount: Int
    var hasChanges: Bool
    var restoreDefaults: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Current policy")
                        .font(.headline)
                    Spacer()
                    Button("Restore Defaults", action: restoreDefaults)
                        .controlSize(.small)
                        .help("Use the default policy: ask for delete, destroy, and remove; block nothing")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        CommandPolicyMetric(
                            title: "Ask before delivery",
                            value: askCount,
                            systemImage: "exclamationmark.triangle",
                            tint: .orange
                        )
                        CommandPolicyMetric(
                            title: "Never deliver",
                            value: blockCount,
                            systemImage: "hand.raised",
                            tint: .red
                        )
                        CommandPolicyMetric(
                            title: hasChanges ? "Unsaved" : "Saved",
                            value: hasChanges ? 1 : 0,
                            systemImage: hasChanges ? "pencil.circle" : "checkmark.circle",
                            tint: hasChanges ? .accentColor : .green
                        )
                    }

                    VStack(spacing: 10) {
                        CommandPolicyMetric(
                            title: "Ask before delivery",
                            value: askCount,
                            systemImage: "exclamationmark.triangle",
                            tint: .orange
                        )
                        CommandPolicyMetric(
                            title: "Never deliver",
                            value: blockCount,
                            systemImage: "hand.raised",
                            tint: .red
                        )
                        CommandPolicyMetric(
                            title: hasChanges ? "Unsaved" : "Saved",
                            value: hasChanges ? 1 : 0,
                            systemImage: hasChanges ? "pencil.circle" : "checkmark.circle",
                            tint: hasChanges ? .accentColor : .green
                        )
                    }
                }

                Text("Defaults ask before `delete`, `destroy`, and `remove`. No command is blocked by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

private struct CommandPolicyMetric: View {
    var title: String
    var value: Int
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(valueText)
                    .font(.headline)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var valueText: String {
        title == "Unsaved" || title == "Saved" ? title : "\(value) terms"
    }
}

private struct CommandPolicyAddRulePanel: View {
    @Binding var text: String
    @Binding var disposition: CommandPolicyDisposition
    var existingTerms: [String]
    var add: (String, CommandPolicyDisposition) -> Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a rule")
                        .font(.headline)
                    Text("Use a single lowercase word fragment, like `delete`, `remove`, or `shutdown`.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ruleInput
                        actionPicker
                            .frame(width: 220)
                        addButton
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ruleInput
                        HStack(spacing: 10) {
                            actionPicker
                            addButton
                            Spacer(minLength: 0)
                        }
                    }
                }

                if validation != .valid || !text.isEmpty {
                    ValidationMessage(validation: validation)
                }

                PolicySuggestionStrip(
                    selectedDisposition: disposition,
                    existingTerms: existingTerms,
                    add: addSuggestedTerm
                )
            }
            .padding(.vertical, 2)
        }
    }

    private var ruleInput: some View {
        TextField("Command word", text: $text, prompt: Text(disposition.placeholder))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Command policy term")
            .onSubmit(addIfValid)
    }

    private var actionPicker: some View {
        Picker("Rule behavior", selection: $disposition) {
            ForEach(CommandPolicyDisposition.allCases) { option in
                Label(option.shortTitle, systemImage: option.systemImage)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Rule behavior")
        .help("Choose whether matching commands require approval or are blocked")
    }

    private var addButton: some View {
        Button {
            addIfValid()
        } label: {
            Label("Add Rule", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .disabled(validation != .valid)
        .help(validation.help)
    }

    private var normalizedTerm: String {
        CommandPolicyTermValidator.normalized(text)
    }

    private var validation: PolicyTermValidation {
        CommandPolicyTermValidator.validate(normalizedTerm, existing: existingTerms)
    }

    private func addIfValid() {
        guard validation == .valid else { return }
        if add(normalizedTerm, disposition) {
            text = ""
        }
    }

    private func addSuggestedTerm(_ term: String) {
        guard add(term, disposition) else { return }
        if CommandPolicyTermValidator.normalized(text) == term {
            text = ""
        }
    }
}

private struct ValidationMessage: View {
    var validation: PolicyTermValidation

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: validation == .valid ? "info.circle" : "exclamationmark.triangle")
                .foregroundStyle(validation == .valid ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            Text(validation.message)
                .font(.caption)
                .foregroundStyle(validation == .valid ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PolicySuggestionStrip: View {
    var selectedDisposition: CommandPolicyDisposition
    var existingTerms: [String]
    var add: (String) -> Void

    private var suggestions: [String] {
        switch selectedDisposition {
        case .destructive:
            ["delete", "remove", "destroy", "drop", "truncate"]
        case .forbidden:
            ["shutdown", "reboot", "format", "wipe"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggestions")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        add(suggestion)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(existingTerms.contains(suggestion))
                    .help("Add \(suggestion) as \(selectedDisposition.shortTitle.lowercased()) rule")
                }
            }
        }
    }
}

private struct CommandPolicyTwoColumnRulesPanel: View {
    var terms: [CommandPolicyTermDraft]
    var move: (String, CommandPolicyDisposition) -> Void
    var remove: (String) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Policy lists")
                            .font(.headline)
                        Text("Keep these lists short. Blocked terms take precedence over approval terms.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(terms.count) total")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        CommandPolicyRuleColumn(
                            disposition: .destructive,
                            terms: terms.filter { $0.disposition == .destructive },
                            move: move,
                            remove: remove
                        )
                        CommandPolicyRuleColumn(
                            disposition: .forbidden,
                            terms: terms.filter { $0.disposition == .forbidden },
                            move: move,
                            remove: remove
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        CommandPolicyRuleColumn(
                            disposition: .destructive,
                            terms: terms.filter { $0.disposition == .destructive },
                            move: move,
                            remove: remove
                        )
                        CommandPolicyRuleColumn(
                            disposition: .forbidden,
                            terms: terms.filter { $0.disposition == .forbidden },
                            move: move,
                            remove: remove
                        )
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct CommandPolicyRuleColumn: View {
    var disposition: CommandPolicyDisposition
    var terms: [CommandPolicyTermDraft]
    var move: (String, CommandPolicyDisposition) -> Void
    var remove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: disposition.systemImage)
                    .foregroundStyle(disposition.tint)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(disposition.title)
                        .font(.callout.weight(.semibold))
                    Text(disposition.columnDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(terms.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            if terms.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(disposition.emptyTitle)
                        .font(.callout.weight(.semibold))
                    Text(disposition.emptyDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    ForEach(terms) { draft in
                        PolicyRuleRow(
                            draft: draft,
                            setDisposition: { move(draft.term, $0) },
                            remove: { remove(draft.term) }
                        )

                        if draft.id != terms.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PolicyRuleRow: View {
    var draft: CommandPolicyTermDraft
    var setDisposition: (CommandPolicyDisposition) -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.disposition.systemImage)
                .foregroundStyle(draft.disposition.tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.term)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(draft.disposition.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Picker("Action for \(draft.term)", selection: Binding(
                get: { draft.disposition },
                set: { setDisposition($0) }
            )) {
                ForEach(CommandPolicyDisposition.allCases) { option in
                    Text(option.shortTitle).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .help("Change how \(draft.term) is handled")

            Button(role: .destructive, action: remove) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(draft.term)")
            .help("Remove \(draft.term) from command policy")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

private struct CommandPolicyPreviewPanel: View {
    @Binding var command: String
    var destructiveTerms: [String]
    var forbiddenTerms: [String]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Preview")
                        .font(.headline)
                    Text("Test a command locally. This does not save policy or contact the daemon.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("hcloud server delete prod-db-01", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Command policy preview command")

                PolicyPreviewResult(classification: classification)

                HStack(spacing: 6) {
                    SampleCommandButton(title: "Delete", command: "hcloud server delete prod-db-01", selection: $command)
                    SampleCommandButton(title: "Remove", command: "gh release remove v1.0.0", selection: $command)
                    SampleCommandButton(title: "Read", command: "hcloud server list", selection: $command)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        }
    }

    private var classification: PolicyPreviewClassification {
        CommandPolicyPreviewClassifier.classify(
            command: command,
            destructiveTerms: destructiveTerms,
            forbiddenTerms: forbiddenTerms
        )
    }
}

private struct PolicyPreviewResult: View {
    var classification: PolicyPreviewClassification

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: classification.systemImage)
                .font(.title3)
                .foregroundStyle(classification.tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(classification.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(classification.tint)
                Text(classification.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(classification.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(classification.tint.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SampleCommandButton: View {
    var title: String
    var command: String
    @Binding var selection: String

    var body: some View {
        Button(title) {
            selection = command
        }
        .controlSize(.small)
        .help("Preview: \(command)")
    }
}

private struct CommandPolicyNotes: View {
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Label("Matching is token-based; one short word is easier to audit than a phrase.", systemImage: "text.magnifyingglass")
                Label("Blocked rules take precedence over approval rules.", systemImage: "hand.raised")
                Label("Policy runs before any secret material is resolved.", systemImage: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        } label: {
            Text("How matching works")
                .font(.callout.weight(.semibold))
        }
        .padding(12)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct CommandPolicyActionBar: View {
    var hasChanges: Bool
    var canSave: Bool
    var isLoading: Bool
    var saveHelp: String
    var revert: () -> Void
    var save: () -> Void
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            PolicySaveStatus(
                hasChanges: hasChanges,
                canSave: canSave,
                isLoading: isLoading
            )
            Spacer()
            if let cancel {
                Button("Cancel", action: cancel)
                    .help("Close without saving CLI delivery changes")
            }
            Button("Revert", action: revert)
                .disabled(!hasChanges)
                .help("Discard unsaved command policy changes")
            Button("Save CLI Delivery", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || !hasChanges || isLoading)
                .accessibilityLabel("Save CLI delivery settings")
                .help(saveHelp)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct PolicySaveStatus: View {
    var hasChanges: Bool
    var canSave: Bool
    var isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if isLoading {
            return "Checking daemon..."
        }
        if !canSave {
            return "Daemon unavailable"
        }
        return hasChanges ? "Unsaved changes" : "Policy saved"
    }

    private var systemImage: String {
        if isLoading {
            return "arrow.clockwise"
        }
        if !canSave {
            return "exclamationmark.triangle"
        }
        return hasChanges ? "pencil.circle" : "checkmark.circle"
    }

    private var tint: Color {
        if !canSave {
            return .orange
        }
        return hasChanges ? .accentColor : .green
    }
}
