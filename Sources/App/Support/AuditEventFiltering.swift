import AgenticSecretsBroker

enum AuditEventFilter {
    static func filtered(_ events: [AuditEventSummary], query: String) -> [AuditEventSummary] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return events }
        return events.filter { event in
            event.decision.localizedCaseInsensitiveContains(normalizedQuery)
                || event.flow.rawValue.localizedCaseInsensitiveContains(normalizedQuery)
                || event.subjectID.localizedCaseInsensitiveContains(normalizedQuery)
                || event.secretID.localizedCaseInsensitiveContains(normalizedQuery)
                || event.actionClass.localizedCaseInsensitiveContains(normalizedQuery)
                || event.outcome.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    static func selectedVisibleEvent(
        selectedID: AuditEventSummary.ID?,
        visibleEvents: [AuditEventSummary]
    ) -> AuditEventSummary? {
        guard let selectedID else { return nil }
        return visibleEvents.first { $0.id == selectedID }
    }
}
