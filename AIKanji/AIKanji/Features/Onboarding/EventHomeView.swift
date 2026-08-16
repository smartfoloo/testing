import SwiftUI

struct EventHomeView: View {
    let eventId: UUID
    let participantId: UUID
    let inviteCode: String?
    private let eventService = EventService()
    private let negotiationService = NegotiationService()
    @State private var memberEvent: MemberEvent?
    @State private var selectedTab: HomeTab = .requirements
    @State private var progress: EventProgress?
    @State private var readiness: CollectionReadiness?
    @State private var latestRunId: UUID?
    @State private var latestRunAt: Date?
    @State private var decision: EventDecision?
    @State private var chosenRestaurantName: String?
    @State private var decisionNameTask: Task<Void, Never>?
    @State private var decisionNameGeneration = 0
    @State private var errorMessage: String?

    private var isOrganizer: Bool { memberEvent?.role == .organizer }

    private var invitationText: String? {
        guard isOrganizer, let code = inviteCode ?? memberEvent?.inviteCode else { return nil }
        var lines = ["まとメシ「\(memberEvent?.name ?? "集まり")」への招待"]
        if let scheduledAt = memberEvent?.scheduledAt {
            lines.append("日時：\(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
        }
        lines.append("招待：\(InviteLink.shareText(code: code))")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: AppSpacing.xs) {
                if let memberEvent {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppSpacing.lg) { eventMetadata(memberEvent) }
                        VStack(alignment: .leading, spacing: AppSpacing.xs) { eventMetadata(memberEvent) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.xs)
                }
                if decision?.chosenPlaceId != nil {
                    AppCard {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Label(AppCopy.chosen, systemImage: "checkmark.seal.fill")
                                .font(AppTypography.caption.weight(.bold))
                                .foregroundStyle(AppColors.accent)
                            if let chosenRestaurantName {
                                Text(chosenRestaurantName)
                                    .font(AppTypography.section)
                                    .foregroundStyle(AppColors.ink)
                            } else {
                                HStack(spacing: AppSpacing.xs) {
                                    ProgressView().controlSize(.small)
                                    Text("決定したお店を読み込んでいます")
                                        .font(AppTypography.caption)
                                        .foregroundStyle(AppColors.ink.opacity(0.72))
                                }
                            }
                            SecondaryButton(title: "候補を見る", systemImage: "list.bullet") {
                                selectedTab = .candidates
                            }
                            .accessibilityIdentifier("view-chosen-candidate")
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.xs)
                    .accessibilityIdentifier("final-decision-card")
                }
            }
            Group {
                switch selectedTab {
                case .requirements:
                    ConstraintEntryView(
                        eventId: eventId,
                        participantId: participantId,
                        preferencesClosed: readiness?.preferencesClosed
                    )
                case .status:
                    GroupActivityFeedView(eventId: eventId, progress: progress)
                case .candidates:
                    candidatesView
                }
            }
            .frame(maxHeight: .infinity)
            TabPillBar(selection: $selectedTab)
                .padding(.vertical, AppSpacing.sm)
        }
        .background(AppColors.background)
        .navigationTitle(memberEvent?.name ?? "集まり")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let invitationText {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: invitationText) {
                        Label("招待", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-invitation")
                }
            }
            if isOrganizer {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        OrganizerDashboardView(
                            eventId: eventId,
                            isOrganizer: true,
                            decision: $decision,
                            chosenRestaurantName: $chosenRestaurantName
                        )
                    } label: {
                        Text(AppCopy.management)
                    }
                    .accessibilityIdentifier("organizer-management")
                }
            }
        }
        .task { await loadMemberEvent() }
        .task { await listenForRuns() }
        .task { await listenForProgress() }
        .task { await listenForDecision() }
        .task { await listenForPreferenceClosure() }
        .onDisappear { decisionNameTask?.cancel() }
        .negotiationWatcher(participantId: participantId)
        .alert("読み込みに失敗しました", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(errorMessage ?? AppCopy.networkError)
        }
    }

    @ViewBuilder
    private func eventMetadata(_ event: MemberEvent) -> some View {
        if let scheduledAt = event.scheduledAt {
            Label(
                scheduledAt.formatted(date: .abbreviated, time: .shortened),
                systemImage: "calendar"
            )
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.ink.opacity(0.72))
        }
        if readiness?.preferencesClosed == true {
            Label(AppCopy.preferencesClosedBadge, systemImage: "lock.fill")
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .accessibilityIdentifier("event-preferences-closed")
        }
    }

    @ViewBuilder
    private var candidatesView: some View {
        if let latestRunId {
            RecommendationListView(
                runId: latestRunId,
                eventId: eventId,
                isOrganizer: isOrganizer,
                decision: $decision,
                onChosen: { result in
                    Task { await receiveDecision(result) }
                }
            )
        } else {
            EmptyStateView(
                title: "候補はまだありません",
                message: isOrganizer
                    ? "管理画面から条件に合うお店を探してください。"
                    : "幹事がお店を探すと、ここに候補が表示されます。"
            )
            .padding(.horizontal, AppSpacing.lg)
        }
    }

    @MainActor
    private func loadMemberEvent() async {
        do {
            async let loadedEvent = eventService.memberEvent(eventId: eventId)
            async let loadedReadiness = negotiationService.collectionReadiness(eventId: eventId)
            async let loadedRun = negotiationService.latestRun(eventId: eventId)
            let (event, nextReadiness, run) = try await (loadedEvent, loadedReadiness, loadedRun)
            memberEvent = event
            readiness = nextReadiness
            if let runId = event.latestRunId, let runAt = event.latestRunAt {
                applyRun(runId: runId, runAt: runAt)
            }
            if let run { applyRun(runId: run.id, runAt: run.runAt) }
            let loadedDecision = EventDecision(chosenPlaceId: event.chosenPlaceId, chosenAt: event.chosenAt)
            await receiveDecision(loadedDecision, announces: false)
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    @MainActor
    private func listenForRuns() async {
        do {
            let (channel, stream) = try await negotiationService.runUpdates(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            for await update in stream {
                applyRun(runId: update.runId, runAt: update.runAt)
            }
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    @MainActor
    private func listenForProgress() async {
        do {
            let (channel, stream) = try await eventService.progressUpdates(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            progress = try await eventService.eventProgress(eventId: eventId)
            for await _ in stream {
                do {
                    progress = try await eventService.eventProgress(eventId: eventId)
                    readiness = try await negotiationService.collectionReadiness(eventId: eventId)
                } catch {
                    errorMessage = AppCopy.errorMessage(for: error)
                }
            }
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    @MainActor
    private func listenForDecision() async {
        do {
            let (channel, stream) = try await eventService.decisionUpdates(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            for await update in stream { await receiveDecision(update) }
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    @MainActor
    private func listenForPreferenceClosure() async {
        do {
            let (channel, stream) = try await eventService.preferencesClosedUpdates(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            for await _ in stream {
                readiness = try await negotiationService.collectionReadiness(eventId: eventId)
            }
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    @MainActor
    private func applyRun(runId: UUID, runAt: Date) {
        guard RunOrdering.isNewer(
            runAt: runAt,
            runId: runId,
            than: latestRunAt,
            currentRunId: latestRunId
        ) else { return }
        latestRunId = runId
        latestRunAt = runAt
    }

    @MainActor
    private func receiveDecision(_ incoming: EventDecision, announces: Bool = true) async {
        var candidate = incoming
        var authoritativeLegacy = false
        if incoming.chosenPlaceId != nil, incoming.chosenAt == nil {
            do {
                candidate = try await eventService.decision(eventId: eventId)
                authoritativeLegacy = candidate.chosenAt == nil
            } catch {
                errorMessage = AppCopy.errorMessage(for: error)
                return
            }
        }
        applyDecision(candidate, announces: announces, authoritativeLegacy: authoritativeLegacy)
    }

    @MainActor
    private func applyDecision(
        _ candidate: EventDecision,
        announces: Bool,
        authoritativeLegacy: Bool
    ) {
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
                if announces, let name {
                    AccessibilityNotification.Announcement("\(name)に決まりました").post()
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == decisionNameGeneration else { return }
                errorMessage = AppCopy.errorMessage(for: error)
            }
        }
    }
}
