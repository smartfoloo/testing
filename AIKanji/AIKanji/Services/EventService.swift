import Foundation
import Supabase

struct EventService {
    private let client: SupabaseClient

    init(client: SupabaseClient = Supa.client) {
        self.client = client
    }

    private struct CreateEventParams: Encodable {
        let p_name: String
        let p_objective: String
        let p_display_name: String
        let p_travel_reference: String
        let p_travel_reference_place_id: String?
    }

    private struct JoinEventParams: Encodable {
        let p_invite_code: String
        let p_display_name: String
        let p_travel_reference: String
        let p_travel_reference_place_id: String?
    }

    /// Creates the event and its organizer participant in a single transaction.
    func createEvent(
        name: String,
        displayName: String,
        travelReference: TravelReference,
        travelReferencePlaceId: String? = nil,
        objective: EventObjective = .balanced
    ) async throws -> CreatedEvent {
        try await client
            .rpc("fn_create_event", params: CreateEventParams(
                p_name: name,
                p_objective: objective.rawValue,
                p_display_name: displayName,
                p_travel_reference: travelReference.rawValue,
                p_travel_reference_place_id: travelReferencePlaceId
            ))
            .execute()
            .value
    }

    private struct PlaceSearchRequest: Encodable {
        let query: String
    }

    private struct PlaceSearchResponse: Decodable {
        let places: [PlaceSuggestion]
    }

    /// Turns what the participant typed into a real place, so their travel reference can be
    /// stored as `participants.travel_reference_place_id`. The lookup happens server-side in
    /// the `place-search` Edge Function because the Places key lives only in function
    /// secrets; a provider failure answers 502, which the SDK surfaces as a thrown error so
    /// the picker can say "could not search" instead of "no such place".
    func searchPlaces(query: String) async throws -> [PlaceSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: PlaceSearchResponse = try await client.functions.invoke(
            "place-search",
            options: FunctionInvokeOptions(body: PlaceSearchRequest(query: trimmed))
        )
        return response.places
    }

    /// Readable only once the caller is a participant of the event (RLS on `events`).
    func event(inviteCode: String) async throws -> Event {
        try await client
            .from("events")
            .select()
            .eq("invite_code", value: inviteCode)
            .single()
            .execute()
            .value
    }

    func decision(eventId: UUID) async throws -> EventDecision {
        try await client
            .from("events")
            .select("chosen_place_id, chosen_at")
            .eq("id", value: eventId)
            .single()
            .execute()
            .value
    }

    private struct ChooseRestaurantParams: Encodable {
        let p_event_id: UUID
        let p_place_id: String
    }

    func chooseRestaurant(eventId: UUID, placeId: String) async throws -> EventDecision {
        let rows: [EventDecision] = try await client
            .rpc("fn_choose_restaurant", params: ChooseRestaurantParams(
                p_event_id: eventId,
                p_place_id: placeId
            ))
            .execute()
            .value
        guard let decision = rows.first else {
            throw NSError(domain: "EventService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "empty restaurant decision response"
            ])
        }
        return decision
    }

    func restaurantName(placeId: String) async throws -> String? {
        struct NameRow: Decodable {
            let name: String?
        }
        let row: NameRow = try await client
            .from("restaurant_features")
            .select("name")
            .eq("place_id", value: placeId)
            .single()
            .execute()
            .value
        return row.name
    }

    private struct RoleRow: Decodable {
        let role: ParticipantRole
    }

    func role(participantId: UUID) async throws -> ParticipantRole {
        let row: RoleRow = try await client
            .from("participants")
            .select("role")
            .eq("id", value: participantId)
            .single()
            .execute()
            .value
        return row.role
    }

    func joinEvent(
        inviteCode: String,
        displayName: String,
        travelReference: TravelReference,
        travelReferencePlaceId: String? = nil
    ) async throws -> UUID {
        try await client
            .rpc("fn_join_event", params: JoinEventParams(
                p_invite_code: inviteCode,
                p_display_name: displayName,
                p_travel_reference: travelReference.rawValue,
                p_travel_reference_place_id: travelReferencePlaceId
            ))
            .execute()
            .value
    }
}
