import Foundation
import Supabase

struct NegotiationService {
    private let client: SupabaseClient

    init(client: SupabaseClient = Supa.client) {
        self.client = client
    }

    // MARK: - Participant side

    /// RLS restricts `negotiations` to rows targeting the caller, so no client-side
    /// filtering by participant is needed for correctness — the id is passed only to
    /// keep the query narrow.
    func pendingNegotiation(participantId: UUID) async throws -> PendingNegotiation? {
        let rows: [PendingNegotiation] = try await client
            .from("negotiations")
            .select("id, proposed_value, unlocked_count, participant_constraints(normalized_type, normalized_value, raw_text)")
            .eq("participant_id", value: participantId)
            .eq("status", value: NegotiationStatus.proposed.rawValue)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private struct RespondParams: Encodable {
        let p_negotiation_id: UUID
        let p_accept: Bool
    }

    /// Accepting rewrites the participant's own constraint and recomputes feasibility
    /// server-side; the RPC rejects any caller other than the targeted participant.
    func respond(negotiationId: UUID, accept: Bool) async throws -> FeasibilityResult? {
        try await client
            .rpc("fn_respond_negotiation", params: RespondParams(
                p_negotiation_id: negotiationId,
                p_accept: accept
            ))
            .execute()
            .value
    }

    // MARK: - Organizer side (aggregates only)

    private struct EventParams: Encodable {
        let p_event_id: UUID
    }

    func responseCount(eventId: UUID) async throws -> Int {
        try await client
            .rpc("fn_get_response_count", params: EventParams(p_event_id: eventId))
            .execute()
            .value
    }

    /// Bare count of open negotiations — deliberately no participant or constraint id.
    func pendingNegotiationCount(eventId: UUID) async throws -> Int {
        try await client
            .rpc("fn_get_pending_negotiation_count", params: EventParams(p_event_id: eventId))
            .execute()
            .value
    }

    func latestRun(eventId: UUID) async throws -> RecommendationRun? {
        let rows: [RecommendationRun] = try await client
            .from("recommendation_runs")
            .select("id, event_id, run_at, feasible_count")
            .eq("event_id", value: eventId)
            .order("run_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private struct SearchRequest: Encodable {
        let event_id: UUID
    }

    private struct SearchResponse: Decodable {
        let candidate_count: Int
    }

    func findRestaurants(eventId: UUID) async throws -> Int {
        let response: SearchResponse = try await client.functions.invoke(
            "restaurant-search",
            options: FunctionInvokeOptions(body: SearchRequest(event_id: eventId))
        )
        return response.candidate_count
    }

    func recomputeFeasibility(eventId: UUID) async throws -> FeasibilityResult {
        try await client
            .rpc("fn_recompute_feasibility", params: EventParams(p_event_id: eventId))
            .execute()
            .value
    }

    /// Returns nil when nothing relaxable would unlock a candidate — the engine hands
    /// off to the human organizer rather than forcing a proposal.
    func proposeRelaxation(eventId: UUID) async throws -> UUID? {
        try await client
            .rpc("fn_propose_relaxation", params: EventParams(p_event_id: eventId))
            .execute()
            .value
    }

    // MARK: - Live run updates

    /// Subscribes to `run_updated` on the private `event-{id}` topic, so the dashboard's
    /// feasible count is push-driven rather than polled.
    func runUpdates(eventId: UUID) async throws -> (channel: RealtimeChannelV2, stream: AsyncStream<RunUpdate>) {
        let channel = client.channel("event-\(eventId.uuidString.lowercased())") { config in
            config.isPrivate = true
        }
        let broadcasts = channel.broadcastStream(event: "run_updated")
        try await channel.subscribeWithError()

        let stream = AsyncStream<RunUpdate> { continuation in
            let task = Task {
                for await message in broadcasts {
                    guard let payload = message["payload"]?.objectValue,
                          let data = try? JSONEncoder().encode(payload),
                          let update = try? JSONDecoder().decode(RunUpdate.self, from: data)
                    else { continue }
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return (channel, stream)
    }
}
