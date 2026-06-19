import AgenticSecretsBroker
import SwiftUI

struct CommandPolicyTermDraft: Identifiable, Equatable, Comparable {
    var term: String
    var disposition: CommandPolicyDisposition

    var id: String { term }

    static func < (lhs: CommandPolicyTermDraft, rhs: CommandPolicyTermDraft) -> Bool {
        if lhs.disposition != rhs.disposition {
            return lhs.disposition.sortOrder < rhs.disposition.sortOrder
        }
        return lhs.term < rhs.term
    }

    static func from(destructiveTerms: [String], forbiddenTerms: [String]) -> [CommandPolicyTermDraft] {
        let forbidden = Set(CommandPolicyConfig.normalizedTerms(forbiddenTerms))
        let destructive = Set(CommandPolicyConfig.normalizedTerms(destructiveTerms)).subtracting(forbidden)
        return (
            destructive.map { CommandPolicyTermDraft(term: $0, disposition: .destructive) }
                + forbidden.map { CommandPolicyTermDraft(term: $0, disposition: .forbidden) }
        ).sorted()
    }

    static func destructiveTerms(from drafts: [CommandPolicyTermDraft]) -> [String] {
        CommandPolicyConfig.normalizedTerms(drafts.compactMap { draft in
            draft.disposition == .destructive ? draft.term : nil
        })
    }

    static func forbiddenTerms(from drafts: [CommandPolicyTermDraft]) -> [String] {
        CommandPolicyConfig.normalizedTerms(drafts.compactMap { draft in
            draft.disposition == .forbidden ? draft.term : nil
        })
    }
}

struct CommandPolicySettingsDraftState: Equatable {
    var terms: [CommandPolicyTermDraft]
    var cliAuthorizationMode: DeliveryAuthorizationMode
    private(set) var baseline: CommandPolicyTermBaseline
    private(set) var deliveryBaseline: DeliveryDefaultsBaseline
    private(set) var hasLoadedBaseline: Bool

    init(
        baseline: CommandPolicyTermBaseline = .default,
        deliveryBaseline: DeliveryDefaultsBaseline = .default,
        hasLoadedBaseline: Bool = false
    ) {
        self.terms = baseline.drafts
        self.cliAuthorizationMode = deliveryBaseline.cliAuthorizationMode
        self.baseline = baseline
        self.deliveryBaseline = deliveryBaseline
        self.hasLoadedBaseline = hasLoadedBaseline
    }

    var hasChanges: Bool {
        baseline.destructiveTerms != CommandPolicyTermDraft.destructiveTerms(from: terms)
            || baseline.forbiddenTerms != CommandPolicyTermDraft.forbiddenTerms(from: terms)
            || deliveryBaseline.cliAuthorizationMode != cliAuthorizationMode
    }

    mutating func sync(summary: CommandPolicySummary?, deliveryDefaults: DeliveryDefaultsSummary?, force: Bool) {
        guard force || !hasLoadedBaseline || !hasChanges else { return }
        let nextBaseline = CommandPolicyTermBaseline(summary: summary)
        let nextDeliveryBaseline = DeliveryDefaultsBaseline(summary: deliveryDefaults)
        baseline = nextBaseline
        deliveryBaseline = nextDeliveryBaseline
        terms = nextBaseline.drafts
        cliAuthorizationMode = nextDeliveryBaseline.cliAuthorizationMode
        hasLoadedBaseline = true
    }
}

struct CommandPolicyTermBaseline: Equatable {
    var destructiveTerms: [String]
    var forbiddenTerms: [String]

    init(destructiveTerms: [String], forbiddenTerms: [String]) {
        self.destructiveTerms = CommandPolicyConfig.normalizedTerms(destructiveTerms)
        self.forbiddenTerms = CommandPolicyConfig.normalizedTerms(forbiddenTerms)
    }

    init(summary: CommandPolicySummary?) {
        self.init(
            destructiveTerms: summary?.destructiveTerms ?? CommandPolicyConfig.default.destructiveTerms,
            forbiddenTerms: summary?.forbiddenTerms ?? CommandPolicyConfig.default.forbiddenTerms
        )
    }

    static let `default` = CommandPolicyTermBaseline(
        destructiveTerms: CommandPolicyConfig.default.destructiveTerms,
        forbiddenTerms: CommandPolicyConfig.default.forbiddenTerms
    )

    var drafts: [CommandPolicyTermDraft] {
        CommandPolicyTermDraft.from(
            destructiveTerms: destructiveTerms,
            forbiddenTerms: forbiddenTerms
        )
    }
}

struct DeliveryDefaultsBaseline: Equatable {
    var cliAuthorizationMode: DeliveryAuthorizationMode

    init(cliAuthorizationMode: DeliveryAuthorizationMode) {
        self.cliAuthorizationMode = cliAuthorizationMode
    }

    init(summary: DeliveryDefaultsSummary?) {
        self.init(cliAuthorizationMode: summary?.cliAuthorizationMode ?? DeliveryDefaultsConfig.default.cliAuthorizationMode)
    }

    static let `default` = DeliveryDefaultsBaseline(
        cliAuthorizationMode: DeliveryDefaultsConfig.default.cliAuthorizationMode
    )
}

extension DeliveryAuthorizationMode: Identifiable {
    public var id: String { rawValue }
}

enum CLIDeliveryAuthorizationChoice: CaseIterable, Identifiable {
    case always
    case remember24h
    case once

    var id: DeliveryAuthorizationMode { mode }

    var mode: DeliveryAuthorizationMode {
        switch self {
        case .always:
            .always
        case .remember24h:
            .remember24h
        case .once:
            .once
        }
    }

    var title: String {
        switch self {
        case .always:
            "Never ask again"
        case .remember24h:
            "Remember for 24 hours"
        case .once:
            "Always ask"
        }
    }

    var detail: String {
        switch self {
        case .always:
            "After one approval, matching non-destructive CLI delivery can reuse the remembered grant until policy or target scope changes."
        case .remember24h:
            "After one approval, matching non-destructive delivery can run without another prompt for one day."
        case .once:
            "Every run asks again. This is slower, but easiest to audit when a CLI is still being evaluated."
        }
    }

    var systemImage: String {
        switch self {
        case .always:
            "infinity"
        case .remember24h:
            "clock"
        case .once:
            "person.badge.key"
        }
    }

    var accent: Color {
        switch self {
        case .always:
            .green
        case .remember24h:
            .blue
        case .once:
            .orange
        }
    }

}

enum CommandPolicyDisposition: String, CaseIterable, Identifiable, Hashable {
    case destructive
    case forbidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .destructive:
            "Ask Before Delivery"
        case .forbidden:
            "Never Deliver"
        }
    }

    var shortTitle: String {
        switch self {
        case .destructive:
            "Ask"
        case .forbidden:
            "Block"
        }
    }

    var inputLabel: String {
        switch self {
        case .destructive:
            "destructive command term"
        case .forbidden:
            "forbidden command term"
        }
    }

    var opposite: CommandPolicyDisposition {
        switch self {
        case .destructive:
            .forbidden
        case .forbidden:
            .destructive
        }
    }

    var detail: String {
        switch self {
        case .destructive:
            "Requires fresh approval before secret delivery."
        case .forbidden:
            "Blocks secret delivery before policy authorization."
        }
    }

    var columnDetail: String {
        switch self {
        case .destructive:
            "Always require user approval."
        case .forbidden:
            "Always deny before delivery."
        }
    }

    var placeholder: String {
        switch self {
        case .destructive:
            "delete"
        case .forbidden:
            "shutdown"
        }
    }

    var moveTitle: String {
        switch self {
        case .destructive:
            "Move to Block"
        case .forbidden:
            "Move to Ask"
        }
    }

    var emptyTitle: String {
        switch self {
        case .destructive:
            "No approval terms"
        case .forbidden:
            "No blocked terms"
        }
    }

    var emptyDetail: String {
        switch self {
        case .destructive:
            "Commands that match no term continue through normal trust checks."
        case .forbidden:
            "This is the default: no command words are blocked outright."
        }
    }

    var systemImage: String {
        switch self {
        case .destructive:
            "exclamationmark.triangle"
        case .forbidden:
            "hand.raised"
        }
    }

    var tint: Color {
        switch self {
        case .destructive:
            .orange
        case .forbidden:
            .red
        }
    }

    var sortOrder: Int {
        switch self {
        case .destructive:
            0
        case .forbidden:
            1
        }
    }
}

enum PolicyPreviewClassification: Equatable {
    case standard
    case destructive(String)
    case forbidden(String)

    var title: String {
        switch self {
        case .standard:
            "Allowed"
        case .destructive:
            "Ask Before Delivery"
        case .forbidden:
            "Blocked"
        }
    }

    var detail: String {
        switch self {
        case .standard:
            "No local policy term matched. Secret delivery continues through normal trust checks."
        case .destructive(let term):
            "Matched '\(term)'. A remembered grant is not enough; the user must approve this run."
        case .forbidden(let term):
            "Matched '\(term)'. The daemon denies delivery before resolving any secret material."
        }
    }

    var shortDetail: String {
        switch self {
        case .standard:
            "No policy match"
        case .destructive(let term):
            "Matched '\(term)'"
        case .forbidden(let term):
            "Matched '\(term)'"
        }
    }

    var systemImage: String {
        switch self {
        case .standard:
            "checkmark.circle"
        case .destructive:
            "exclamationmark.triangle"
        case .forbidden:
            "hand.raised"
        }
    }

    var tint: Color {
        switch self {
        case .standard:
            .green
        case .destructive:
            .orange
        case .forbidden:
            .red
        }
    }
}

enum PolicyTermValidation: Equatable {
    case valid
    case empty
    case duplicate
    case invalidCharacters

    var message: String {
        switch self {
        case .valid:
            "Terms are matched as lowercase command word fragments."
        case .empty:
            "Enter one command word or fragment."
        case .duplicate:
            "This term is already in the policy."
        case .invalidCharacters:
            "Use one term without spaces or separators such as / . _ - : =."
        }
    }

    var help: String {
        switch self {
        case .valid:
            "Add term to command policy"
        case .empty:
            "Enter a term first"
        case .duplicate:
            "Choose a term that is not already listed"
        case .invalidCharacters:
            "Use a single word or fragment because command matching is token-based"
        }
    }
}

enum CommandPolicyTermValidator {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func validate(_ term: String, existing: [String]) -> PolicyTermValidation {
        if term.isEmpty {
            return .empty
        }
        if existing.contains(term) {
            return .duplicate
        }
        if term.contains(where: isSeparator) {
            return .invalidCharacters
        }
        return .valid
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "/"
            || character == "\\"
            || character == "."
            || character == "_"
            || character == "-"
            || character == ":"
            || character == "="
            || character.isWhitespace
    }
}

enum CommandPolicyPreviewClassifier {
    static func classify(command: String, destructiveTerms: [String], forbiddenTerms: [String]) -> PolicyPreviewClassification {
        let tokens = commandPolicyTokens(command)
        if let term = firstMatch(tokens: tokens, terms: forbiddenTerms) {
            return .forbidden(term)
        }
        if let term = firstMatch(tokens: tokens, terms: destructiveTerms) {
            return .destructive(term)
        }
        return .standard
    }

    private static func firstMatch(tokens: [String], terms: [String]) -> String? {
        CommandPolicyConfig.normalizedTerms(terms).first { term in
            tokens.contains { $0.contains(term) }
        }
    }

    private static func commandPolicyTokens(_ value: String) -> [String] {
        value
            .lowercased()
            .split { character in
                character == "/" || character == "\\" || character == "." || character == "_" || character == "-" || character == ":" || character == "=" || character.isWhitespace
            }
            .map(String.init)
    }
}
