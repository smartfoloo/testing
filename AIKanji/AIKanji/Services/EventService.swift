import Foundation
import Supabase

struct EventService {
    private let client: SupabaseClient

    init(client: SupabaseClient = Supa.client) {
        self.client = client
    }

    private struct CreateEventParams: Encodable {
        let p_name: String
        let p_display_name: String
        let p_scheduled_at: Date?
        let p_origin_label: String
        let p_origin_latitude: Double
        let p_origin_longitude: Double
        let p_objective: String
        let p_travel_reference: String
        let p_travel_reference_place_id: String?
    }

    private struct InviteCodeParams: Encodable {
        let p_invite_code: String
    }

    private struct JoinEventParams: Encodable {
        let p_invite_code: String
        let p_display_name: String
        let p_origin_label: String
        let p_origin_latitude: Double
        let p_origin_longitude: Double
        let p_travel_reference: String
        let p_travel_reference_place_id: String?
    }

    private struct EventParams: Encodable {
        let p_event_id: UUID
    }

    func createEvent(
        name: String,
        displayName: String,
        scheduledAt: Date?,
        origin: OriginSelection,
        objective: EventObjective = .balanced
    ) async throws -> CreatedEvent {
        let response = try await client
            .rpc("fn_create_event_v2", params: CreateEventParams(
                p_name: name,
                p_display_name: displayName,
                p_scheduled_at: scheduledAt,
                p_origin_label: origin.label,
                p_origin_latitude: origin.latitude,
                p_origin_longitude: origin.longitude,
                p_objective: objective.rawValue,
                p_travel_reference: TravelReference.station.rawValue,
                p_travel_reference_place_id: nil
            ))
            .execute()
        return try Self.decodeSingle(CreatedEvent.self, from: response.data)
    }

    func previewEvent(inviteCode: String) async throws -> EventPreview {
        let response = try await client
            .rpc("fn_preview_event_v2", params: InviteCodeParams(p_invite_code: inviteCode))
            .execute()
        return try Self.decodeSingle(EventPreview.self, from: response.data)
    }

    func joinEvent(inviteCode: String, displayName: String, origin: OriginSelection) async throws -> UUID {
        try await client
            .rpc("fn_join_event_v2", params: JoinEventParams(
                p_invite_code: inviteCode,
                p_display_name: displayName,
                p_origin_label: origin.label,
                p_origin_latitude: origin.latitude,
                p_origin_longitude: origin.longitude,
                p_travel_reference: TravelReference.station.rawValue,
                p_travel_reference_place_id: nil
            ))
            .execute()
            .value
    }

    func myEvents() async throws -> [MemberEvent] {
        let response = try await client
            .rpc("fn_get_my_events_v2")
            .execute()
        return try Self.rpcDecoder.decode([MemberEvent].self, from: response.data)
    }

    func memberEvent(eventId: UUID) async throws -> MemberEvent {
        guard let event = try await myEvents().first(where: { $0.eventId == eventId }) else {
            throw NSError(domain: "EventService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "event is not available to this member"
            ])
        }
        return event
    }

    func eventProgress(eventId: UUID) async throws -> EventProgress {
        let response = try await client
            .rpc("fn_get_event_progress_v2", params: EventParams(p_event_id: eventId))
            .execute()
        return try Self.decodeSingle(EventProgress.self, from: response.data)
    }

    private struct PlaceSearchRequest: Encodable {
        let query: String
    }

    private struct PlaceSearchResponse: Decodable {
        let places: [PlaceSuggestion]
    }

    func searchPlaces(query: String) async throws -> [PlaceSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: PlaceSearchResponse = try await client.functions.invoke(
            "place-search",
            options: FunctionInvokeOptions(body: PlaceSearchRequest(query: trimmed))
        )
        return response.places
    }

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

    func progressUpdates(
        eventId: UUID
    ) async throws -> (channel: RealtimeTopicSubscription, stream: AsyncStream<Void>) {
        let (subscription, broadcasts) = try await RealtimeTopicRegistry.shared.subscribe(
            topic: RealtimeTopicRegistry.eventTopic(eventId: eventId),
            event: .eventProgressUpdated,
            client: client
        )
        return (subscription, invalidationStream(broadcasts))
    }

    func decisionUpdates(
        eventId: UUID
    ) async throws -> (channel: RealtimeTopicSubscription, stream: AsyncStream<EventDecision>) {
        let (subscription, broadcasts) = try await RealtimeTopicRegistry.shared.subscribe(
            topic: RealtimeTopicRegistry.eventTopic(eventId: eventId),
            event: .eventDecided,
            client: client
        )
        return (subscription, decodeStream(broadcasts, as: EventDecision.self))
    }

    func preferencesClosedUpdates(
        eventId: UUID
    ) async throws -> (channel: RealtimeTopicSubscription, stream: AsyncStream<Void>) {
        let (subscription, broadcasts) = try await RealtimeTopicRegistry.shared.subscribe(
            topic: RealtimeTopicRegistry.eventTopic(eventId: eventId),
            event: .preferencesClosed,
            client: client
        )
        return (subscription, invalidationStream(broadcasts))
    }

    private func invalidationStream(
        _ broadcasts: AsyncStream<[String: AnyJSON]>
    ) -> AsyncStream<Void> {
        AsyncStream<Void> { continuation in
            let task = Task {
                for await _ in broadcasts { continuation.yield(()) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func decodeStream<Value: Decodable & Sendable>(
        _ broadcasts: AsyncStream<[String: AnyJSON]>,
        as type: Value.Type
    ) -> AsyncStream<Value> {
        AsyncStream<Value> { continuation in
            let task = Task {
                for await message in broadcasts {
                    guard let payload = message["payload"]?.objectValue,
                          let update = try? Self.decodeBroadcast(type, from: payload)
                    else { continue }
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func decodeSingle<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        if let value = try? rpcDecoder.decode(Value.self, from: data) {
            return value
        }
        let rows = try rpcDecoder.decode([Value].self, from: data)
        guard let value = rows.first else {
            throw NSError(domain: "EventService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "empty RPC response"
            ])
        }
        return value
    }

    private static func decodeBroadcast<Value: Decodable>(
        _ type: Value.Type,
        from payload: [String: AnyJSON]
    ) throws -> Value {
        let data = try JSONEncoder().encode(payload)
        return try rpcDecoder.decode(Value.self, from: data)
    }

    private static let rpcDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized timestamp: \(text)")
        }
        return decoder
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
