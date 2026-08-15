import SwiftUI

/// Landing screen once a participant belongs to an event.
struct EventHomeView: View {
    let eventId: UUID
    let participantId: UUID
    let inviteCode: String?

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
        }
        .navigationTitle(inviteCode.map { "Code \($0)" } ?? "Event")
        .navigationBarTitleDisplayMode(.inline)
    }
}
