import Foundation

enum EventObjective: String, Codable, CaseIterable, Identifiable {
    case balanced, access, cost, experience, custom
    var id: String { rawValue }
}

enum EventStatus: String, Codable {
    case collecting, negotiating, ready, closed
}

struct Event: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let inviteCode: String
    let organizerParticipantId: UUID?
    let objective: EventObjective
    let status: EventStatus
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case inviteCode = "invite_code"
        case organizerParticipantId = "organizer_participant_id"
        case objective
        case status
        case createdAt = "created_at"
    }
}

/// Payload returned by the `fn_create_event` RPC.
struct CreatedEvent: Codable, Hashable {
    let eventId: UUID
    let inviteCode: String

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case inviteCode = "invite_code"
    }
}
