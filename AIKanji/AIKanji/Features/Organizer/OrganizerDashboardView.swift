import Foundation
import SwiftUI

@MainActor
final class OrganizerDashboardViewModel: ObservableObject {
    @Published var responseCount = 0
    @Published var feasibleCount: Int?
    @Published var openNegotiations = 0
    @Published var latestRunId: UUID?
    /// When the shortlist on screen was computed, so a run that predates the close can be
    /// told apart from one that answers it.
    @Published var latestRunAt: Date?
    @Published var readiness: CollectionReadiness?
    /// Readiness as it stood when the run currently on screen landed.
    @Published var runBasis: CollectionReadiness?
    @Published var isWorking = false
    @Published var isClosing = false
    @Published var isConfirmingClose = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    private let service: NegotiationService
    init(service: NegotiationService = NegotiationService()) { self.service = service }
    var negotiationInProgress: Bool { openNegotiations > 0 }

    var preferencesClosed: Bool { readiness?.preferencesClosed ?? false }

    var closedAtText: String? { AppCopy.closedAt(readiness?.closedAt) }

    /// Answers can still arrive, so anything computed now is provisional — whether or not the
    /// threshold has been reached. PRD §12 wants that said out loud, not implied.
    var resultsProvisional: Bool {
        guard let readiness else { return false }
        return !readiness.preferencesClosed && !readiness.isComplete
    }

    /// The shortlist on screen predates the close, so it is not the post-close answer yet.
    /// PRD §12: that recalculation is the organizer's explicit act, never a side effect.
    var needsRecompute: Bool {
        guard preferencesClosed, let closedAt = readiness?.closedAt else { return false }
        guard let latestRunAt else { return true }
        return latestRunAt < closedAt
    }

    /// 回答数 counts people once readiness is known: `fn_get_response_count` returns constraint
    /// rows, which reads as "10 answers from 5 people" and overstates the coverage the
    /// shortlist is actually based on.
    var responseCountValue: String {
        guard let readiness else { return "\(responseCount)" }
        return "\(readiness.respondedCount)/\(readiness.participantCount)"
    }

    @discardableResult
    func refreshReadiness(eventId: UUID) async -> CollectionReadiness? {
        do {
            let next = try await service.collectionReadiness(eventId: eventId)
            readiness = next
            return next
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
            return nil
        }
    }

    func load(eventId: UUID) async {
        do {
            responseCount = try await service.responseCount(eventId: eventId)
            openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
            if let run = try await service.latestRun(eventId: eventId) {
                feasibleCount = run.feasibleCount
                latestRunId = run.id
                latestRunAt = run.runAt
            }
        } catch { errorMessage = AppCopy.networkError }
        await refreshReadiness(eventId: eventId)
    }

    func listenForRuns(eventId: UUID) async {
        do {
            let (channel, stream) = try await service.runUpdates(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            for await update in stream {
                feasibleCount = update.feasibleCount
                latestRunId = update.runId
                latestRunAt = Date()
                do {
                    openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
                    responseCount = try await service.responseCount(eventId: eventId)
                } catch {
                    errorMessage = AppCopy.networkError
                }
                // Keep the readiness readout in step with the run that just arrived.
                if let next = await refreshReadiness(eventId: eventId) { runBasis = next }
            }
        } catch { errorMessage = AppCopy.networkError }
    }

    /// How long a burst of submissions is allowed to keep collapsing into one recompute.
    /// Five people answering at once should cost one run, not five: recompute walks the whole
    /// venue pool and writes a `recommendation_runs` row, and every row broadcasts to everybody.
    private static let staleDebounce = Duration.milliseconds(1500)

    /// Listens for 0029's `feasibility_stale` and recomputes ONCE per burst, so the dashboard
    /// is live without anybody pressing 「もう一度計算する」.
    ///
    /// Each signal restarts the timer rather than queueing a recompute, so a run happens
    /// `staleDebounce` after the LAST change, not once per change.
    ///
    /// GATED ON A RUN ALREADY EXISTING. Before the organizer has searched there are no
    /// candidates for this event, so recompute would truthfully answer 0 and the dashboard
    /// would show 「条件を満たすお店 0」 to a group that has not looked for one yet — worse than
    /// the button it replaces. Once a run exists, keeping it current is exactly the promise.
    func listenForStaleFeasibility(eventId: UUID) async {
        do {
            let (channel, stream) = try await service.feasibilityStaleSignals(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            var pending: Task<Void, Never>?
            defer { pending?.cancel() }
            for await staleAt in stream {
                guard shouldAutoRecompute(staleAt: staleAt) else { continue }
                pending?.cancel()
                pending = Task { [weak self] in
                    try? await Task.sleep(for: Self.staleDebounce)
                    guard !Task.isCancelled, let self else { return }
                    // Re-checked after the wait, not only before it: the burst that armed this
                    // timer may have ended with the organizer closing collection, or with a
                    // consent whose own recompute already counted the change.
                    guard self.shouldAutoRecompute(staleAt: staleAt) else { return }
                    await self.recomputeAfterChange(eventId: eventId)
                }
            }
        } catch { errorMessage = AppCopy.networkError }
    }

    /// The three conditions under which a change is worth recomputing for on its own. Kept
    /// identical to the web dashboard's gates, because the two clients are deliberately 1:1 and
    /// an organizer watching on a phone must not see a different number from one watching in a
    /// browser.
    ///
    ///   1. a run already exists — before the first search there are no candidates, so an
    ///      automatic recompute would render a confident 0 meaning "nobody has looked yet";
    ///   2. collection is still open — recalculating after the 幹事 closed it is their explicit
    ///      act (PRD §12), which is why `fn_close_preferences` does not recompute either;
    ///   3. the change is not already counted by the run on screen — which makes a REPLAYED
    ///      message harmless (Realtime hands a fresh subscriber whatever is in the topic) and
    ///      keeps a consent quiet, since `fn_respond_negotiation` marks stale and recomputes in
    ///      the same transaction.
    private func shouldAutoRecompute(staleAt: Date) -> Bool {
        guard latestRunId != nil, !preferencesClosed else { return false }
        guard let latestRunAt else { return true }
        return staleAt > latestRunAt
    }

    /// The automatic half of `recompute`: no spinner and no status message, because nobody
    /// asked for this and a banner appearing on its own would read as an error. The count
    /// updates, and the `run_updated` broadcast the new run fires keeps every other screen —
    /// including this one on another device — in step through the existing path.
    private func recomputeAfterChange(eventId: UUID) async {
        guard !isWorking else { return }
        do {
            let result = try await service.recomputeFeasibility(eventId: eventId)
            feasibleCount = result.feasibleCount
            latestRunId = result.runId
            latestRunAt = Date()
            if let next = await refreshReadiness(eventId: eventId) { runBasis = next }
        } catch {
            // Deliberately silent. A background refresh that failed is not something the
            // organizer did, and the button is still there to try again on purpose.
        }
    }

    func findRestaurants(eventId: UUID) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        do {
            let candidates = try await service.findRestaurants(eventId: eventId)
            let result = try await service.recomputeFeasibility(eventId: eventId)
            feasibleCount = result.feasibleCount
            latestRunId = result.runId
            latestRunAt = Date()
            if result.feasibleCount == 0 {
                statusMessage = try await service.proposeRelaxation(eventId: eventId) == nil
                    ? "今の条件では、まだ候補が見つかりません。みんなで相談してみましょう。"
                    : "条件に合うお店がありません。参加者に条件の変更をお願いしました。"
                do {
                    openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
                } catch {
                    errorMessage = AppCopy.networkError
                }
            } else if candidates == 0 {
                statusMessage = "以前に取得した候補を表示しています。"
            }
        } catch { errorMessage = AppCopy.networkError }
        // The search is what makes the numbers move, so re-read them instead of going stale.
        if let next = await refreshReadiness(eventId: eventId) { runBasis = next }
        isWorking = false
    }

    /// Organizer-only, idempotent, and deliberately without a recompute: closing states the
    /// consequences first (see the confirmation sheet) and only moves the marker.
    func closePreferences(eventId: UUID) async {
        // fn_close_preferences is idempotent, but a double tap would still fire two RPCs.
        guard !isClosing, !preferencesClosed else { return }
        isClosing = true
        errorMessage = nil
        statusMessage = nil
        do {
            readiness = try await service.closePreferences(eventId: eventId)
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
        isClosing = false
        isConfirmingClose = false
    }
}

/// Progress towards the threshold. The filled part is answers received; the notch is the
/// point at which a shortlist stops being a coin flip (`least(n, greatest(3, ceil(0.6n)))`).
private struct ReadinessBar: View {
    let readiness: CollectionReadiness

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColors.accentSoft)
                Capsule().fill(AppColors.accent).frame(width: proxy.size.width * filledFraction)
                if readiness.thresholdCount < readiness.participantCount {
                    Rectangle()
                        .fill(AppColors.ink.opacity(0.45))
                        .frame(width: 2)
                        .offset(x: proxy.size.width * markFraction)
                }
            }
        }
        .frame(height: AppSpacing.xs)
        .accessibilityElement()
        .accessibilityLabel(AppCopy.collectionProgress)
        .accessibilityValue(AppCopy.readinessCounts(readiness))
        .accessibilityIdentifier("readiness-progress")
    }

    private var total: Double { Double(max(readiness.participantCount, 1)) }

    private var filledFraction: Double {
        min(1, max(0, Double(readiness.respondedCount) / total))
    }

    private var markFraction: Double {
        min(1, max(0, Double(readiness.thresholdCount) / total))
    }
}

/// A calm status pill, matching the 調整中… treatment but without the warning yellow.
private struct StatePill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(AppTypography.caption.weight(.bold))
            .foregroundStyle(AppColors.ink)
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: 36)
            .background(tint)
            .clipShape(Capsule())
    }
}

struct OrganizerDashboardView: View {
    let eventId: UUID
    let isOrganizer: Bool
    @Binding var decision: EventDecision?
    @Binding var chosenRestaurantName: String?
    @StateObject private var viewModel = OrganizerDashboardViewModel()
    @State private var openRunId: UUID?
    private let eventService = EventService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                header
                statTiles
                if let readiness = viewModel.readiness {
                    readinessCard(readiness)
                }
                if viewModel.negotiationInProgress {
                    StatePill(title: "調整中…", tint: AppColors.yellow)
                }
                searchSection
                recommendationsSection
                closeSection
                decisionCard
                footerSection
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .navigationDestination(item: $openRunId) { runId in
            RecommendationListView(
                runId: runId,
                eventId: eventId,
                isOrganizer: isOrganizer,
                onChosen: { result in
                    decision = result
                    Task {
                        if let placeId = result.chosenPlaceId {
                            do {
                                chosenRestaurantName = try await eventService.restaurantName(placeId: placeId)
                            } catch {
                                viewModel.errorMessage = AppCopy.errorMessage(for: error)
                            }
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $viewModel.isConfirmingClose) { closeSheet }
        .task { await viewModel.load(eventId: eventId) }
        .task { await viewModel.listenForRuns(eventId: eventId) }
        // A separate .task, not a branch inside listenForRuns: the two consume different
        // broadcast events off the same shared channel, and SwiftUI cancels each with the
        // view. RealtimeTopicRegistry multiplexes them onto one topic subscription.
        .task { await viewModel.listenForStaleFeasibility(eventId: eventId) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(AppCopy.homeOrganizer).font(AppTypography.title)
            Text("みんなの条件を集計して、お店を探します。")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.ink.opacity(0.72))
        }
    }

    private var statTiles: some View {
        HStack(spacing: AppSpacing.sm) {
            StatTile(value: viewModel.responseCountValue, title: "回答数", tint: AppColors.card)
                .accessibilityIdentifier("response-count")
            StatTile(value: viewModel.feasibleCount.map(String.init) ?? "—", title: "条件を満たすお店", tint: (viewModel.feasibleCount ?? 0) > 0 ? AppColors.accentSoft : AppColors.card)
                .accessibilityIdentifier("feasible-count")
        }
    }

    /// Searching early is never blocked: PRD §12 would rather label a result provisional than
    /// hold the group up for one silent colleague. After a close, the recompute is prompted
    /// for — never performed as a side effect of closing.
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if viewModel.needsRecompute {
                Text(AppCopy.recomputeRequired)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(AppColors.greenSoft)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .accessibilityIdentifier("recompute-required")
            }
            PrimaryButton(title: AppCopy.findRestaurants, isLoading: viewModel.isWorking) {
                Task { await viewModel.findRestaurants(eventId: eventId) }
            }
            .accessibilityIdentifier("find-restaurants")
        }
    }

    @ViewBuilder
    private var recommendationsSection: some View {
        if let runId = viewModel.latestRunId, (viewModel.feasibleCount ?? 0) > 0 {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Button("おすすめを見る") { openRunId = runId }
                    .frame(maxWidth: .infinity).frame(minHeight: 48)
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.ink)
                    .background(AppColors.card)
                    .overlay(Capsule().strokeBorder(AppColors.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .clipShape(Capsule())
                    .accessibilityIdentifier("recommendations")
                Text(AppCopy.resultBasis(viewModel.runBasis))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .accessibilityIdentifier("result-basis")
            }
        }
    }

    @ViewBuilder
    private var closeSection: some View {
        if !viewModel.preferencesClosed {
            SecondaryButton(title: AppCopy.closePreferences) {
                viewModel.isConfirmingClose = true
            }
            .accessibilityIdentifier("close-preferences")
            .disabled(viewModel.readiness == nil || viewModel.isClosing)
        }
    }

    @ViewBuilder
    private var decisionCard: some View {
        if decision?.chosenPlaceId != nil {
            AppCard {
                Label(
                    chosenRestaurantName.map { "\(AppCopy.chosen)：\($0)" } ?? AppCopy.chosen,
                    systemImage: "checkmark.seal.fill"
                )
                    .foregroundStyle(AppColors.accent)
            }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("誰がどの条件を出したかは表示せず、集計結果だけを共有します。")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.ink.opacity(0.72))
            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage).font(AppTypography.body)
            }
            if let errorMessage = viewModel.errorMessage {
                InlineErrorView(message: errorMessage) { Task { await viewModel.load(eventId: eventId) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Responses as people against the threshold, plus what that means and what the 幹事 can
    /// do about it — never a bare row count.
    private func readinessCard(_ readiness: CollectionReadiness) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AppCopy.collectionProgress).font(AppTypography.section)
                    Spacer()
                    if viewModel.preferencesClosed {
                        StatePill(title: AppCopy.preferencesClosedBadge, tint: AppColors.greenSoft)
                            .accessibilityIdentifier("preferences-closed")
                    } else if viewModel.resultsProvisional {
                        Text(AppCopy.provisionalBadge)
                            .font(AppTypography.small.weight(.bold))
                            .foregroundStyle(AppColors.ink)
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xxs)
                            .background(AppColors.accentSoft)
                            .clipShape(Capsule())
                            .accessibilityIdentifier("provisional-badge")
                    }
                }
                ReadinessBar(readiness: readiness)
                Text(AppCopy.readinessCounts(readiness))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .accessibilityIdentifier("readiness-counts")
                Text(AppCopy.readinessSummary(readiness))
                    .font(AppTypography.body)
                    .accessibilityIdentifier("readiness-summary")
                Text(AppCopy.readinessHint(readiness))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .accessibilityIdentifier("readiness-hint")
                if viewModel.preferencesClosed, let closedAtText = viewModel.closedAtText {
                    Text(closedAtText)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                        .accessibilityIdentifier("preferences-closed-at")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("collection-readiness")
        }
    }

    /// Closing is a considered action, so the three consequences are stated before the tap:
    /// participants can no longer add or change requirements (RLS refuses the write, so their
    /// save fails loudly), closing does not recompute, and it cannot be undone.
    private var closeSheet: some View {
        BottomSheetScaffold(title: AppCopy.closePreferencesQuestion) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text(AppCopy.closePreferencesEffect).font(AppTypography.body)
                Text(AppCopy.closePreferencesNoRecompute).font(AppTypography.body)
                Text(AppCopy.closePreferencesIrreversible)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                if let readiness = viewModel.readiness {
                    Text(AppCopy.closeSnapshot(readiness))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                        .accessibilityIdentifier("close-preferences-snapshot")
                }
                PrimaryButton(title: AppCopy.closePreferencesConfirm, isLoading: viewModel.isClosing) {
                    Task { await viewModel.closePreferences(eventId: eventId) }
                }
                .accessibilityIdentifier("close-preferences-confirm")
                SecondaryButton(title: AppCopy.cancel) { viewModel.isConfirmingClose = false }
                    .accessibilityIdentifier("close-preferences-cancel")
                    .disabled(viewModel.isClosing)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("close-preferences-sheet")
        }
        .interactiveDismissDisabled(viewModel.isClosing)
    }
}
