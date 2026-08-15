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
    }

    private struct JoinEventParams: Encodable {
        let p_invite_code: String
        let p_display_name: String
        let p_travel_reference: String
        let p_travel_reference_place_id: String?
    }

    func createEvent(name: String, objective: EventObjective = .balanced) async throws -> CreatedEvent {
        try await client
            .rpc("fn_create_event", params: CreateEventParams(p_name: name, p_objective: objective.rawValue))
            .execute()
            .value
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
