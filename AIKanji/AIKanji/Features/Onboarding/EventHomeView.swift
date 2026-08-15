import SwiftUI

struct EventHomeView: View {
    let eventId: UUID
    let participantId: UUID
    let inviteCode: String?
    private let eventService = EventService()
    @State private var role: ParticipantRole?
    @State private var selectedTab: HomeTab = .requirements
    @State private var decision: EventDecision?
    @State private var chosenRestaurantName: String?
    @State private var decisionError: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .requirements:
                    ConstraintEntryView(eventId: eventId, participantId: participantId)
                case .group:
                    GroupActivityFeedView(eventId: eventId)
                case .organizer:
                    OrganizerDashboardView(
                        eventId: eventId,
                        isOrganizer: role == .organizer,
                        decision: $decision,
                        chosenRestaurantName: $chosenRestaurantName
                    )
                }
            }
            .frame(maxHeight: .infinity)
            TabPillBar(selection: $selectedTab, showsOrganizer: role == .organizer)
                .padding(.vertical, AppSpacing.sm)
        }
        .background(AppColors.background)
        .navigationTitle(inviteCode.map { "集まり \($0)" } ?? "集まり")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if decision?.chosenPlaceId != nil {
                Text(chosenRestaurantName.map { "\(AppCopy.chosen)：\($0)" } ?? AppCopy.chosen)
                    .font(AppTypography.caption.weight(.bold))
                    .foregroundStyle(AppColors.ink)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.yellow)
                    .clipShape(Capsule())
                    .padding(.top, AppSpacing.xs)
            }
        }
        .task {
            do {
                role = try await eventService.role(participantId: participantId)
                decision = try await eventService.decision(eventId: eventId)
                if let chosenPlaceId = decision?.chosenPlaceId {
                    chosenRestaurantName = try await eventService.restaurantName(placeId: chosenPlaceId)
                }
            } catch {
                decisionError = AppCopy.errorMessage(for: error)
            }
        }
        .negotiationWatcher(participantId: participantId)
        .alert("読み込みに失敗しました", isPresented: Binding(
            get: { decisionError != nil },
            set: { if !$0 { decisionError = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(decisionError ?? AppCopy.networkError)
        }
    }
}
