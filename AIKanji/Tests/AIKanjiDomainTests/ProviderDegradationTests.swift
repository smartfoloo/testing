import Foundation
import Supabase
import XCTest

/// Provider-degradation evidence for the hosted Edge Functions.
final class ProviderDegradationTests: XCTestCase {
    private struct ExplainRequest: Encodable {
        let mode = "explain"
        let run_id: UUID
        let restaurant_place_id: String
        let evidence: String?
    }

    private struct ExplainResponse: Decodable {
        let explanation: String
    }

    private struct RespondParams: Encodable {
        let p_negotiation_id: UUID
        let p_accept: Bool
    }

    private struct FeasibilityResult: Decodable {
        let runId: UUID?
        let feasibleCount: Int

        enum CodingKeys: String, CodingKey {
            case runId = "run_id"
            case feasibleCount = "feasible_count"
        }
    }

    private struct ScoreRow: Decodable {
        let restaurantPlaceId: String

        enum CodingKeys: String, CodingKey {
            case restaurantPlaceId = "restaurant_place_id"
        }
    }

    private struct SearchRequest: Encodable {
        let event_id: UUID
    }

    override func setUp() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SUPABASE_URL"] == nil,
            "Supabase configuration not provided to the test runner"
        )
        try await DemoFixture.reset()
    }

    override func tearDown() async throws {
        if ProcessInfo.processInfo.environment["SUPABASE_URL"] != nil {
            try await restoreExpectedFixture()
        }
        try await super.tearDown()
    }

    func test01_explainFallsBackWhenLlmKeyIsUnset() async throws {
        let (client, runId, placeId) = try await prepareRecommendationRun()
        let response: ExplainResponse = try await withTimeout(seconds: 20) {
            try await client.functions.invoke(
                "llm-assist",
                options: FunctionInvokeOptions(
                    body: ExplainRequest(
                        run_id: runId,
                        restaurant_place_id: placeId,
                        evidence: nil
                    )
                )
            )
        }

        XCTAssertFalse(response.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func test02_explainIgnoresClientSuppliedGrounding() async throws {
        let (client, runId, placeId) = try await prepareRecommendationRun()
        let fabricated = "has a fully private room for 40 people at ¥999"
        let response: ExplainResponse = try await withTimeout(seconds: 20) {
            try await client.functions.invoke(
                "llm-assist",
                options: FunctionInvokeOptions(
                    body: ExplainRequest(
                        run_id: runId,
                        restaurant_place_id: placeId,
                        evidence: fabricated
                    )
                )
            )
        }

        XCTAssertFalse(response.explanation.contains(fabricated))
    }

    func test03_restaurantSearchRejectsNonexistentEvent() async throws {
        let client = try await DemoFixture.client(as: .alice)
        let nonexistentEventId = UUID(uuidString: "00000000-0000-0000-0000-00000000dead")!

        do {
            _ = try await withTimeout(seconds: 20) {
                try await client.functions.invoke(
                    "restaurant-search",
                    options: FunctionInvokeOptions(
                        body: SearchRequest(event_id: nonexistentEventId)
                    ),
                    decode: { data, response in
                        XCTAssertEqual(response.statusCode, 200)
                        return data
                    }
                )
            }
            XCTFail("restaurant-search should reject a nonexistent event")
        } catch is TimeoutError {
            XCTFail("restaurant-search timed out for a nonexistent event")
        } catch let FunctionsError.httpError(code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("restaurant-search returned an unexpected error: \(error)")
        }
    }

    private func prepareRecommendationRun() async throws -> (SupabaseClient, UUID, String) {
        let organizer = try await DemoFixture.client(as: .alice)
        let baseline: FeasibilityResult = try await organizer
            .rpc("fn_recompute_feasibility", params: ["p_event_id": DemoFixture.eventId.uuidString])
            .execute()
            .value
        XCTAssertEqual(baseline.feasibleCount, 0)

        let negotiationData = try await organizer
            .rpc("fn_propose_relaxation", params: ["p_event_id": DemoFixture.eventId.uuidString])
            .execute()
            .data
        let negotiationId = try XCTUnwrap(
            UUID(uuidString: String(decoding: negotiationData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\n")))
        )

        let bob = try await DemoFixture.client(as: .bob)
        let accepted: FeasibilityResult = try await bob
            .rpc("fn_respond_negotiation", params: RespondParams(
                p_negotiation_id: negotiationId,
                p_accept: true
            ))
            .execute()
            .value
        XCTAssertEqual(accepted.feasibleCount, 3)

        let rerun: FeasibilityResult = try await organizer
            .rpc("fn_recompute_feasibility", params: ["p_event_id": DemoFixture.eventId.uuidString])
            .execute()
            .value
        let scores: [ScoreRow] = try await organizer
            .from("recommendation_scores")
            .select("restaurant_place_id")
            .eq("run_id", value: try XCTUnwrap(rerun.runId))
            .limit(1)
            .execute()
            .value
        let placeId = try XCTUnwrap(scores.first?.restaurantPlaceId)
        return (organizer, try XCTUnwrap(rerun.runId), placeId)
    }

    private func restoreExpectedFixture() async throws {
        try await DemoFixture.reset()
        let organizer = try await DemoFixture.client(as: .alice)
        let result: FeasibilityResult = try await organizer
            .rpc("fn_recompute_feasibility", params: ["p_event_id": DemoFixture.eventId.uuidString])
            .execute()
            .value
        XCTAssertEqual(result.feasibleCount, 0)

        let data = try await organizer
            .rpc("fn_propose_relaxation", params: ["p_event_id": DemoFixture.eventId.uuidString])
            .execute()
            .data
        XCTAssertNotEqual(
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\"\n")),
            "null"
        )
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct TimeoutError: Error {}
}
