import SwiftUI

/// Landing screen once a participant belongs to an event.
struct EventHomeView: View {
    let eventId: UUID
    let participantId: UUID
    let inviteCode: String?

    private let eventService = EventService()

    @State private var role: ParticipantRole?

    var body: some View {
        TabView {
            NavigationStack {
                ConstraintEntryView(eventId: eventId, participantId: participantId)
            }
            .tabItem { Label("Requirements", systemImage: "checklist") }

            NavigationStack {
                GroupActivityFeedView(eventId: eventId)
            }
            .tabItem { Label("Group", systemImage: "person.3") }

            if role == .organizer {
                NavigationStack {
                    OrganizerDashboardView(eventId: eventId)
                }
                .tabItem { Label("Organizer", systemImage: "slider.horizontal.3") }
            }
        }
        .navigationTitle(inviteCode.map { "Code \($0)" } ?? "Event")
        .navigationBarTitleDisplayMode(.inline)
        .negotiationWatcher(participantId: participantId)
        .task { role = try? await eventService.role(participantId: participantId) }
    }
}
