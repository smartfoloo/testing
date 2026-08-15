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

    /// PRD §12: how far collection has come, counted in **people** against the threshold
    /// `least(n, greatest(3, ceil(0.6n)))`, so a shortlist can be produced (and labelled
    /// provisional) before the last colleague has answered.
    func collectionReadiness(eventId: UUID) async throws -> CollectionReadiness {
        try await client
            .rpc("fn_get_collection_readiness", params: EventParams(p_event_id: eventId))
            .execute()
            .value
    }

    /// `fn_close_preferences` returns only the two lifecycle columns.
    private struct ClosePreferencesRow: Decodable {
        let preferencesClosedAt: String?
        /// Kept as text: `events.status` is a text column with a CHECK, and an unrecognised
        /// value must not fail the close the organizer just performed.
        let status: String?

        enum CodingKeys: String, CodingKey {
            case preferencesClosedAt = "preferences_closed_at"
            case status
        }
    }

    /// Organizer-only and idempotent. Deliberately does **not** recompute: PRD §12 requires
    /// post-close recalculation to be an explicit act by the 幹事, never a side effect of
    /// closing. The RPC answers with the lifecycle columns only, so the full readiness
    /// payload is re-read for the caller.
    func closePreferences(eventId: UUID) async throws -> CollectionReadiness {
        let rows: [ClosePreferencesRow] = try await client
            .rpc("fn_close_preferences", params: EventParams(p_event_id: eventId))
            .execute()
            .value
        guard !rows.isEmpty else {
            throw NSError(domain: "NegotiationService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "empty close-preferences response"
            ])
        }
        return try await collectionReadiness(eventId: eventId)
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
    /// feasible count is push-driven rather than polled. Aggregates only: the payload the
    /// trigger sends carries a run id and a count, never a participant.
    ///
    /// The channel comes from `RealtimeTopicRegistry` because the group feed listens for
    /// `constraint_added` on this same topic, and Realtime keys channels by topic — a second
    /// channel here would fight the feed's instead of multiplexing with it. What is handed
    /// back is this listener's hold on the shared channel, which
    /// `Supa.client.removeChannel(_:)` releases; the channel goes only with the last release.
    func runUpdates(eventId: UUID) async throws -> (channel: RealtimeTopicSubscription, stream: AsyncStream<RunUpdate>) {
        let (subscription, broadcasts) = try await RealtimeTopicRegistry.shared.subscribe(
            topic: RealtimeTopicRegistry.eventTopic(eventId: eventId),
            event: .runUpdated,
            client: client
        )

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

        return (subscription, stream)
    }
}
