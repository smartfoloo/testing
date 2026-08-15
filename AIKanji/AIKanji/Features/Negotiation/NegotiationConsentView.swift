import SwiftUI

/// Consent sheet for a single relaxation proposal. Only the targeted participant can
/// fetch the row behind it (RLS) or respond to it (the RPC re-checks the caller).
struct NegotiationConsentView: View {
    let negotiation: PendingNegotiation
    let onResponse: (Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(negotiation.question).font(.headline)
                    Text(negotiation.impact).foregroundStyle(.secondary)
                }

                Section("You originally said") {
                    Text(negotiation.constraint.rawText).foregroundStyle(.secondary)
                }

                Section {
                    Button(isSubmitting ? "Sending…" : "Accept") {
                        Task { await respond(accept: true) }
                    }
                    .disabled(isSubmitting)

                    Button("Keep my requirement", role: .destructive) {
                        Task { await respond(accept: false) }
                    }
                    .disabled(isSubmitting)
                } footer: {
                    Text("Declining is fine — the group only sees that a change was asked for, not what you chose.")
                }
            }
            .navigationTitle("One quick question")
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func respond(accept: Bool) async {
        isSubmitting = true
        await onResponse(accept)
        isSubmitting = false
        dismiss()
    }
}

/// Watches for a proposal aimed at this participant and presents the consent sheet.
/// Attach to the participant's home screen.
struct NegotiationWatcher: ViewModifier {
    let participantId: UUID

    private let service = NegotiationService()
    private static let pollInterval: Duration = .seconds(5)

    @State private var pending: PendingNegotiation?

    func body(content: Content) -> some View {
        content
            .sheet(item: $pending) { negotiation in
                NegotiationConsentView(negotiation: negotiation) { accept in
                    _ = try? await service.respond(negotiationId: negotiation.id, accept: accept)
                    pending = nil
                }
            }
            .task { await watch() }
    }

    private func watch() async {
        while !Task.isCancelled {
            if pending == nil {
                pending = try? await service.pendingNegotiation(participantId: participantId)
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

extension View {
    func negotiationWatcher(participantId: UUID) -> some View {
        modifier(NegotiationWatcher(participantId: participantId))
    }
}
