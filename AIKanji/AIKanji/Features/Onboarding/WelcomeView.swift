import SwiftUI

struct WelcomeView: View {
    private enum Destination: Hashable {
        case create
        case join
    }

    private let service = EventService()
    @State private var isLoginPresented = false
    @State private var signedInEmail: String?
    @State private var events: [MemberEvent] = []
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var isHistoryExpanded = false
    @State private var destination: Destination?
    @State private var linkedInviteCode: String?

    private var currentEvents: [MemberEvent] {
        events
            .filter { $0.status != .closed && $0.chosenPlaceId == nil }
            .sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
    }

    private var decidedEvents: [MemberEvent] {
        events
            .filter { $0.status == .closed || $0.chosenPlaceId != nil }
            .sorted { ($0.scheduledAt ?? .distantPast) > ($1.scheduledAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()
                if isLoading && !hasLoaded {
                    ProgressView(AppCopy.loading)
                        .foregroundStyle(AppColors.ink)
                } else if events.isEmpty {
                    emptyWelcome
                } else {
                    eventsWelcome
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .create: CreateEventView()
                case .join: JoinEventView()
                }
            }
            .navigationDestination(item: $linkedInviteCode) { code in
                JoinEventView(initialCode: code)
            }
            .onOpenURL { url in
                let code = JoinEventView.extractInviteCode(from: url.absoluteString)
                if code.count == 6 { linkedInviteCode = code }
            }
        }
        .task {
            await loadEvents()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-AIKanjiUITestCreate") {
                destination = .create
            }
#endif
        }
        .onAppear {
            if hasLoaded && !isLoading {
                Task { await loadEvents() }
            }
        }
        .sheet(isPresented: $isLoginPresented) {
            LoginSheet(
                currentEmail: signedInEmail,
                onSignedIn: { email in
                    signedInEmail = email
                    Task { await loadEvents() }
                },
                onSignedOut: {
                    signedInEmail = nil
                    Task { await loadEvents() }
                }
            )
        }
    }

    private var emptyWelcome: some View {
        ScrollView {
            VStack(spacing: AppSpacing.xl) {
                brandHeader
                Text(AppCopy.tagline)
                    .font(AppTypography.body.weight(.medium))
                    .foregroundStyle(AppColors.ink)
                    .multilineTextAlignment(.center)
                actionButtons
                if let errorMessage {
                    InlineErrorView(message: errorMessage) { Task { await loadEvents() } }
                }
                loginSection
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.xxl)
        }
    }

    private var eventsWelcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                brandHeader
                    .frame(maxWidth: .infinity)
                if !currentEvents.isEmpty {
                    eventSection(title: AppCopy.currentEvents, events: currentEvents)
                }
                if !decidedEvents.isEmpty {
                    DisclosureGroup("過去の集まり", isExpanded: $isHistoryExpanded) {
                        eventSection(title: "", events: decidedEvents)
                            .padding(.top, AppSpacing.sm)
                    }
                    .font(AppTypography.section)
                    .tint(AppColors.accent)
                }
                actionButtons
                if let errorMessage {
                    InlineErrorView(message: errorMessage) { Task { await loadEvents() } }
                }
                loginSection
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.xl)
        }
        .refreshable { await loadEvents() }
    }

    private var brandHeader: some View {
        VStack(spacing: AppSpacing.sm) {
            Text(AppCopy.appName).font(AppTypography.display).foregroundStyle(AppColors.ink)
            Text("みんなの希望を、ひとつに")
                .font(AppTypography.caption.weight(.bold))
                .foregroundStyle(AppColors.accent)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: AppSpacing.sm) {
            Button {
                destination = .create
            } label: {
                Text(AppCopy.create).frame(maxWidth: .infinity).frame(minHeight: 48)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.accentForeground)
            .background(AppColors.accent)
            .clipShape(Capsule())
            .accessibilityIdentifier("create-event")

            Button {
                destination = .join
            } label: {
                Text(AppCopy.join).frame(maxWidth: .infinity).frame(minHeight: 48)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.ink)
            .background(AppColors.card)
            .overlay(Capsule().strokeBorder(AppColors.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .clipShape(Capsule())
            .accessibilityIdentifier("join-event")
        }
    }

    private var loginSection: some View {
        VStack(spacing: AppSpacing.xs) {
            Button(signedInEmail == nil ? AppCopy.login : "アカウント") {
                isLoginPresented = true
            }
            .font(AppTypography.body.weight(.semibold))
            .foregroundStyle(AppColors.accent)
            .frame(minHeight: 44)
            .accessibilityIdentifier("login")
            Text(AppCopy.optionalLogin)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .multilineTextAlignment(.center)
            if let signedInEmail {
                Text(signedInEmail)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .accessibilityIdentifier("signed-in-email")
            }
        }
    }

    private func eventSection(title: String, events: [MemberEvent]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if !title.isEmpty {
                Text(title).font(AppTypography.section)
            }
            ForEach(events) { event in
                NavigationLink {
                    EventHomeView(
                        eventId: event.eventId,
                        participantId: event.participantId,
                        inviteCode: event.inviteCode
                    )
                } label: {
                    AppCard {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Text(event.name)
                                .font(AppTypography.section)
                                .foregroundStyle(AppColors.ink)
                            if let scheduledAt = event.scheduledAt {
                                Label(
                                    scheduledAt.formatted(date: .abbreviated, time: .shortened),
                                    systemImage: "calendar"
                                )
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColors.ink.opacity(0.72))
                            }
                            if event.chosenPlaceId == nil {
                                ProgressView(value: Double(event.completedCount), total: Double(max(event.participantCount, 1)))
                                    .tint(AppColors.accent)
                                    .accessibilityLabel("回答状況")
                                    .accessibilityValue("\(event.participantCount)人中\(event.completedCount)人回答あり")
                                Text("\(event.participantCount)人中\(event.completedCount)人回答あり")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(AppColors.ink.opacity(0.72))
                            } else {
                                Label(AppCopy.chosen, systemImage: "checkmark.seal.fill")
                                    .font(AppTypography.caption.weight(.bold))
                                    .foregroundStyle(AppColors.accent)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("event-\(event.eventId.uuidString)")
            }
        }
    }

    @MainActor
    private func loadEvents() async {
        isLoading = true
        errorMessage = nil
        do {
            events = try await service.myEvents()
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
        signedInEmail = await Supa.currentEmail()
        isLoading = false
        hasLoaded = true
    }
}

#Preview { WelcomeView() }
