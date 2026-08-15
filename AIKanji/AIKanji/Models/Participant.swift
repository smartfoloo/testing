import Foundation

enum ParticipantRole: String, Codable {
    case organizer, participant
}

enum TravelReference: String, Codable, CaseIterable, Identifiable {
    case office
    case home
    case station
    case doesntMatter = "doesnt_matter"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .office: return "Office"
        case .home: return "Home"
        case .station: return "Station"
        case .doesntMatter: return "Doesn't matter"
        }
    }
}

struct Participant: Codable, Identifiable, Hashable {
    let id: UUID
    let eventId: UUID
    let authUserId: UUID
    let displayName: String
    let role: ParticipantRole
    let travelReference: TravelReference?
    let travelReferencePlaceId: String?
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case authUserId = "auth_user_id"
        case displayName = "display_name"
        case role
        case travelReference = "travel_reference"
        case travelReferencePlaceId = "travel_reference_place_id"
        case joinedAt = "joined_at"
    }
}
