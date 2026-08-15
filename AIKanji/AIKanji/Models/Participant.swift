import Foundation

enum ParticipantRole: String, Codable {
    case organizer, participant
}

/// PRD §4 lists all four as valid travel references. `doesntMatter` imposes no travel
/// constraint, so the backend excludes those participants from the origins set — and the
/// client must send a nil `travel_reference_place_id` for it.
enum TravelReference: String, Codable, CaseIterable, Identifiable {
    case office
    case home
    case station
    case doesntMatter = "doesnt_matter"

    var id: String { rawValue }

    var label: String {
        AppCopy.travel(self)
    }

    /// A category is not a location: these three stand for a real place the participant has
    /// to pick, or travel fairness is computed from nothing.
    var needsPlace: Bool { self != .doesntMatter }

    /// Label for the place field, phrased for the reference the participant chose.
    var placeLabel: String { AppCopy.travelPlaceLabel(self) }
}

/// A place candidate from the `place-search` Edge Function, for the travel-reference picker.
/// Only `placeId` is ever persisted (by `fn_create_event` / `fn_join_event`); the name and
/// address are provider content shown for recognition and stored nowhere.
struct PlaceSuggestion: Codable, Identifiable, Hashable {
    let placeId: String
    let name: String
    let address: String?

    var id: String { placeId }

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name
        case address
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
