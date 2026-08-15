import Foundation
import Supabase

struct RecommendationService {
    private let client: SupabaseClient

    init(client: SupabaseClient = Supa.client) {
        self.client = client
    }

    func scores(runId: UUID) async throws -> [RecommendationScore] {
        try await client
            .from("recommendation_scores")
            .select()
            .eq("run_id", value: runId)
            .execute()
            .value
    }

    func features(placeIds: [String]) async throws -> [RestaurantFeature] {
        try await client
            .from("restaurant_features")
            // photo_url is selected because a column the client cannot read is a column it
            // cannot display; the web client's features() selects the same set.
            .select(
                "place_id, name, price_yen_estimate, room_type, cuisine_tags, atmosphere_tags, photo_url"
            )
            .in("place_id", values: placeIds)
            .execute()
            .value
    }

    private struct ExplainRequest: Encodable {
        let mode = "explain"
        let run_id: UUID
        let restaurant_place_id: String
    }

    private struct ExplainResponse: Decodable {
        let explanation: String
    }

    /// The Edge Function fetches its own grounding data server-side; only identifiers are
    /// sent, never an evidence blob the model could be steered by.
    func explanation(runId: UUID, restaurantPlaceId: String) async throws -> String {
        let response: ExplainResponse = try await client.functions.invoke(
            "llm-assist",
            options: FunctionInvokeOptions(
                body: ExplainRequest(run_id: runId, restaurant_place_id: restaurantPlaceId)
            )
        )
        return response.explanation
    }
}
