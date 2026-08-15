import SwiftUI

struct NegotiationConsentView: View {
    let negotiation: PendingNegotiation
    let onResponse: (Bool) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        BottomSheetScaffold(title: "ちょっとした確認") {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text(negotiation.question).font(AppTypography.section)
                Text(negotiation.impact).foregroundStyle(AppColors.accent).font(AppTypography.body.weight(.bold))
                if let errorMessage {
                    InlineErrorView(message: errorMessage) {
                        self.errorMessage = nil
                    }
                }
                AppCard {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("あなたの元の要望").font(AppTypography.caption.weight(.bold))
                        Text(negotiation.constraint.rawText).font(AppTypography.body)
                    }
                }
                PrimaryButton(title: AppCopy.negotiationAccept, isLoading: isSubmitting) {
                    Task { await respond(accept: true) }
                }
                .disabled(isSubmitting)
                SecondaryButton(title: AppCopy.negotiationDecline) {
                    Task { await respond(accept: false) }
                }
                .disabled(isSubmitting)
                Text("回答はあなたの希望にだけ反映され、誰が何を選んだかは他の参加者には表示されません。")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func respond(accept: Bool) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        do {
            try await onResponse(accept)
            dismiss()
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
        isSubmitting = false
    }
}

struct NegotiationWatcher: ViewModifier {
    let participantId: UUID
    private let service = NegotiationService()
    private static let pollInterval: Duration = .seconds(5)
    @State private var pending: PendingNegotiation?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if let errorMessage {
                    InlineErrorView(message: errorMessage) {
                        self.errorMessage = nil
                    }
                    .padding(.horizontal, AppSpacing.md)
                }
            }
            .sheet(item: $pending) { negotiation in
                NegotiationConsentView(negotiation: negotiation) { accept in
                    _ = try await service.respond(negotiationId: negotiation.id, accept: accept)
                    pending = nil
                }
            }
            .task { await watch() }
    }

    private func watch() async {
        while !Task.isCancelled {
            if pending == nil {
                do {
                    pending = try await service.pendingNegotiation(participantId: participantId)
                    errorMessage = nil
                } catch {
                    errorMessage = AppCopy.networkError
                }
            }
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return
            }
        }
    }
}

extension View {
    func negotiationWatcher(participantId: UUID) -> some View {
        modifier(NegotiationWatcher(participantId: participantId))
    }
}
