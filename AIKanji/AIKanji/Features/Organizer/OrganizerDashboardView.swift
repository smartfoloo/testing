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
    private var pendingStaleAt: Date?
    private var autoRecomputeTask: Task<Void, Never>?
    private var autoRecomputeWorkTask: Task<Void, Never>?
    private var isAutoRecomputing = false
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
        var staleAt: Date?
        do {
            responseCount = try await service.responseCount(eventId: eventId)
            openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
            if let run = try await service.latestRun(eventId: eventId) {
                applyRun(runId: run.id, runAt: run.runAt, feasibleCount: run.feasibleCount)
            }
            staleAt = try await service.feasibilityStaleAt(eventId: eventId)
        } catch { errorMessage = AppCopy.errorMessage(for: error) }
        await refreshReadiness(eventId: eventId)
        if let staleAt { scheduleAutoRecompute(staleAt: staleAt, eventId: eventId) }
    }

    func listenForRuns(eventId: UUID) async {
        do {
            let (channel, stream) = try await service.runUpdates(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            for await update in stream {
                guard applyRun(
                    runId: update.runId,
                    runAt: update.runAt,
                    feasibleCount: update.feasibleCount
                ) else { continue }
                do {
                    openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
                    responseCount = try await service.responseCount(eventId: eventId)
                } catch {
                    errorMessage = AppCopy.networkError
                }
                // Keep the readiness readout in step with the run that just arrived.
                if let next = await refreshReadiness(eventId: eventId) { runBasis = next }
            }
        } catch { errorMessage = AppCopy.errorMessage(for: error) }
    }

    /// How long a burst of submissions is allowed to keep collapsing into one recompute.
    /// Five people answering at once should cost one run, not five: recompute walks the whole
    /// venue pool and writes a `recommendation_runs` row, and every row broadcasts to everybody.
    private static let staleDebounce = Duration.milliseconds(1500)

    /// Listens for 0029's aggregate-only staleness mark and coalesces a burst into one run.
    func listenForStaleFeasibility(eventId: UUID) async {
        do {
            let (channel, stream) = try await service.feasibilityStaleSignals(eventId: eventId)
            defer {
                autoRecomputeTask?.cancel()
                autoRecomputeWorkTask?.cancel()
                pendingStaleAt = nil
                Task { await Supa.client.removeChannel(channel) }
            }
            for await staleAt in stream {
                scheduleAutoRecompute(staleAt: staleAt, eventId: eventId)
            }
        } catch { errorMessage = AppCopy.errorMessage(for: error) }
    }

    private func scheduleAutoRecompute(staleAt: Date, eventId: UUID) {
        guard shouldAutoRecompute(staleAt: staleAt) else { return }
        if pendingStaleAt == nil || staleAt > pendingStaleAt! { pendingStaleAt = staleAt }
        autoRecomputeTask?.cancel()
        autoRecomputeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.staleDebounce)
            } catch {
                return
            }
            guard let self, let newestStaleAt = self.pendingStaleAt else { return }
            self.autoRecomputeTask = nil
            guard self.shouldAutoRecompute(staleAt: newestStaleAt) else {
                self.pendingStaleAt = nil
                return
            }
            if self.isWorking || self.isAutoRecomputing {
                self.scheduleAutoRecompute(staleAt: newestStaleAt, eventId: eventId)
                return
            }
            self.pendingStaleAt = nil
            let work = Task { [weak self] in
                guard let self else { return }
                await self.recomputeAfterChange(eventId: eventId)
            }
            self.autoRecomputeWorkTask = work
            await work.value
            self.autoRecomputeWorkTask = nil
        }
    }

    private func shouldAutoRecompute(staleAt: Date) -> Bool {
        guard latestRunId != nil, !preferencesClosed else { return false }
        return FeasibilityStaleness.isUncounted(staleAt: staleAt, computedThrough: latestRunAt)
    }

    private func recomputeAfterChange(eventId: UUID) async {
        guard !isWorking, !isAutoRecomputing else { return }
        isAutoRecomputing = true
        defer { isAutoRecomputing = false }
        do {
            _ = try await service.recomputeFeasibility(eventId: eventId)
            guard !Task.isCancelled, !preferencesClosed else { return }
            if let run = try await service.latestRun(eventId: eventId) {
                guard !Task.isCancelled else { return }
                applyRun(runId: run.id, runAt: run.runAt, feasibleCount: run.feasibleCount)
            }
            if let next = await refreshReadiness(eventId: eventId) { runBasis = next }
        } catch {
            // The explicit search action remains available if a background refresh fails.
        }
    }

    func findRestaurants(eventId: UUID) async {
        guard !isWorking, !isAutoRecomputing else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        do {
            let candidates = try await service.findRestaurants(eventId: eventId)
            let result = try await service.recomputeFeasibility(eventId: eventId)
            if let run = try await service.latestRun(eventId: eventId) {
                applyRun(runId: run.id, runAt: run.runAt, feasibleCount: run.feasibleCount)
            } else {
                feasibleCount = result.feasibleCount
            }
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
        } catch { errorMessage = AppCopy.errorMessage(for: error) }
        // The search is what makes the numbers move, so re-read them instead of going stale.
        if let next = await refreshReadiness(eventId: eventId) { runBasis = next }
        isWorking = false
    }

    @discardableResult
    private func applyRun(runId: UUID, runAt: Date, feasibleCount: Int) -> Bool {
        guard RunOrdering.isNewer(
            runAt: runAt,
            runId: runId,
            than: latestRunAt,
            currentRunId: latestRunId
        ) else { return false }
        latestRunId = runId
        latestRunAt = runAt
        self.feasibleCount = feasibleCount
        return true
    }

    /// Organizer-only, idempotent, and deliberately without a recompute: closing states the
    /// consequences first (see the confirmation sheet) and only moves the marker.
    func closePreferences(eventId: UUID) async {
        // fn_close_preferences is idempotent, but a double tap would still fire two RPCs.
        guard !isClosing, !preferencesClosed else { return }
        autoRecomputeTask?.cancel()
        autoRecomputeWorkTask?.cancel()
        pendingStaleAt = nil
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
    @State private var decisionNameTask: Task<Void, Never>?
    @State private var decisionNameGeneration = 0
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
                decision: $decision,
                onChosen: { result in
                    Task { await receiveDecision(result) }
                }
            )
        }
        .sheet(isPresented: $viewModel.isConfirmingClose) { closeSheet }
        .task { await viewModel.load(eventId: eventId) }
        .task { await viewModel.listenForRuns(eventId: eventId) }
        .task { await viewModel.listenForStaleFeasibility(eventId: eventId) }
        .onDisappear { decisionNameTask?.cancel() }
    }

    @MainActor
    private func receiveDecision(_ incoming: EventDecision) async {
        var candidate = incoming
        var authoritativeLegacy = false
        if incoming.chosenPlaceId != nil, incoming.chosenAt == nil {
            do {
                candidate = try await eventService.decision(eventId: eventId)
                authoritativeLegacy = candidate.chosenAt == nil
            } catch {
                viewModel.errorMessage = AppCopy.errorMessage(for: error)
                return
            }
        }
        applyDecision(candidate, authoritativeLegacy: authoritativeLegacy)
    }

    @MainActor
    private func applyDecision(_ candidate: EventDecision, authoritativeLegacy: Bool) {
        guard EventDecisionOrdering.isNewer(
            candidate,
            than: decision,
            authoritativeLegacy: authoritativeLegacy
        ) else { return }
        decision = candidate
        decisionNameGeneration += 1
        let generation = decisionNameGeneration
        decisionNameTask?.cancel()
        chosenRestaurantName = nil
        guard let placeId = candidate.chosenPlaceId else { return }
        decisionNameTask = Task {
            do {
                let name = try await eventService.restaurantName(placeId: placeId)
                try Task.checkCancellation()
                guard generation == decisionNameGeneration,
                      decision?.chosenPlaceId == placeId,
                      decision?.chosenAt == candidate.chosenAt
                else { return }
                chosenRestaurantName = name
            } catch is CancellationError {
                return
            } catch {
                guard generation == decisionNameGeneration else { return }
                viewModel.errorMessage = AppCopy.errorMessage(for: error)
            }
        }
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
