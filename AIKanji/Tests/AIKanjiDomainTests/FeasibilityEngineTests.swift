import Foundation
import Supabase
import XCTest

/// Part A of the verification pass: the deterministic engine and the privacy
/// guarantees, exercised over the RPC surface only — no UI involved.
///
/// Test names are numbered so a plain `xcodebuild test` run executes them in the
/// order of the golden path; every test resets the seeded fixture first, so the
/// whole suite is idempotent and can be run twice consecutively with identical
/// results.
final class FeasibilityEngineTests: XCTestCase {
    private var bobClient: SupabaseClient!

    override func setUp() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SUPABASE_URL"] == nil,
            "Supabase configuration not provided to the test runner"
        )
        try await DemoFixture.reset()
    }

    // 1. Baseline: the five personas' MUSTs leave nothing feasible.
    func test01_baselineFeasibilityIsZero() async throws {
        let client = try await DemoFixture.client(as: .alice)
        let result = try await recompute(client)
        XCTAssertEqual(result.feasibleCount, 0)
    }

    // 2. Relaxation picks Bob's room MUST and quantifies the unlock.
    func test02_relaxationTargetsBobsRoomConstraint() async throws {
        let client = try await DemoFixture.client(as: .alice)
        _ = try await recompute(client)

        let negotiationId = try await propose(client)
        XCTAssertNotNil(negotiationId, "a room MUST should be eligible for relaxation")

        let row = try await DemoFixture.negotiationRow(eventId: DemoFixture.eventId)
        let participantId = (row?["participant_id"] as? String).flatMap(UUID.init(uuidString:))
        XCTAssertEqual(participantId, DemoFixture.bob)
        XCTAssertEqual(row?["unlocked_count"] as? Int, 3)
        XCTAssertEqual((row?["proposed_value"] as? [String: Any])?["room"] as? String, "semi_private")

        let constraintId = (row?["constraint_id"] as? String).flatMap(UUID.init(uuidString:))
        let type = try await DemoFixture.constraintType(id: XCTUnwrap(constraintId))
        XCTAssertEqual(type, "room")
    }

    // 3. Bob accepting unlocks exactly demo_place_001 / 002 / 004 — never 003.
    func test03_acceptingUnlocksExactlyThreeVenues() async throws {
        let organizer = try await DemoFixture.client(as: .alice)
        _ = try await recompute(organizer)
        _ = try await propose(organizer)

        let bob = try await DemoFixture.client(as: .bob)
        let pending: [PendingRow] = try await bob
            .from("negotiations")
            .select("id,status")
            .eq("status", value: "PROPOSED")
            .execute()
            .value
        XCTAssertEqual(pending.count, 1, "only Bob's own negotiation is visible to Bob")

        let accepted = try await respond(bob, negotiationId: pending[0].id, accept: true)
        XCTAssertEqual(accepted.feasibleCount, 3)

        let rerun = try await recompute(organizer)
        XCTAssertEqual(rerun.feasibleCount, 3, "accepting is not a one-off: the state is durable")

        let scores: [ScoreRow] = try await organizer
            .from("recommendation_scores")
            .select("restaurant_place_id,label")
            .eq("run_id", value: rerun.runId.uuidString)
            .execute()
            .value
        XCTAssertEqual(
            scores.map(\.restaurantPlaceId).sorted(),
            ["demo_place_001", "demo_place_002", "demo_place_004"]
        )
        XCTAssertFalse(scores.contains { $0.restaurantPlaceId == "demo_place_003" })
        // Labels are earned, not distributed. Only David has seeded travel legs, so every
        // venue ties on travel fairness and none is demonstrably 'fairest' — that badge goes
        // unused rather than being handed to an arbitrary row, which is what the earlier
        // greedy assignment did (it once badged a 75-minute commute 'best access'). So three
        // scored venues legitimately earn two labels here. Assert the invariant instead of a
        // fixed count: the number depends on how much provider data has been gathered.
        // Mirrors 'no label is applied twice' in supabase/tests/backend_tests.sql.
        let labels = scores.compactMap(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "no label is applied twice")
        XCTAssertFalse(labels.isEmpty, "at least one candidate carries a differentiating label")
    }

    // 4. Safety rule: an allergy MUST is never proposed, even when it is the only
    //    thing standing between the group and a feasible venue.
    func test04_sensitiveMustIsNeverProposed() async throws {
        let organizer = try await DemoFixture.client(as: .alice)
        let created: CreatedEvent = try await organizer
            .rpc("fn_create_event", params: CreateEventParams(
                p_name: "scratch allergy fixture",
                p_display_name: "Alice",
                p_travel_reference: "office",
                p_travel_reference_place_id: nil,
                p_objective: "balanced"
            ))
            .execute()
            .value
        addTeardownBlock { [eventId = created.eventId] in
            try? await DemoFixture.deleteEvent(eventId)
        }
        _ = try await organizer
            .rpc("fn_join_event", params: [
                "p_invite_code": created.inviteCode,
                "p_display_name": "Alice",
                "p_travel_reference": "office",
            ])
            .execute()

        let emma = try await DemoFixture.client(as: .emma)
        let participantId: UUID = try await emma
            .rpc("fn_join_event", params: [
                "p_invite_code": created.inviteCode,
                "p_display_name": "Emma",
                "p_travel_reference": "office",
            ])
            .execute()
            .value
        try await emma
            .from("participant_constraints")
            .insert(ConstraintInsert(
                eventId: created.eventId,
                participantId: participantId,
                rawText: "peanut allergy",
                normalizedValue: ["allergen": "peanut"]
            ))
            .execute()

        let baseline = try await recompute(organizer, eventId: created.eventId)
        XCTAssertEqual(baseline.feasibleCount, 0, "no seeded venue is peanut-safe")

        let negotiationId = try await propose(organizer, eventId: created.eventId)
        XCTAssertNil(negotiationId, "an allergy MUST must never be proposed for relaxation")
        let written = try await DemoFixture.negotiationRow(eventId: created.eventId)
        XCTAssertNil(written)
    }

    // 5. A participant cannot read another participant's raw constraint rows.
    func test05_participantCannotReadOthersRawConstraints() async throws {
        let bob = try await DemoFixture.client(as: .bob)
        let charlies: [ConstraintRow] = try await bob
            .from("participant_constraints")
            .select("id,normalized_type")
            .eq("participant_id", value: DemoFixture.charlie.uuidString)
            .execute()
            .value
        XCTAssertTrue(charlies.isEmpty)

        let own: [ConstraintRow] = try await bob
            .from("participant_constraints")
            .select("id,normalized_type")
            .eq("participant_id", value: DemoFixture.bob.uuidString)
            .execute()
            .value
        XCTAssertFalse(own.isEmpty, "Bob can still read his own rows — the test is not passing vacuously")
    }

    // 6. The organizer has no negotiation read access at all, only aggregates.
    func test06_organizerSeesAggregatesOnlyNotNegotiations() async throws {
        let organizer = try await DemoFixture.client(as: .alice)
        _ = try await recompute(organizer)
        let negotiationId = try await propose(organizer)
        XCTAssertNotNil(negotiationId)

        let visible: [PendingRow] = try await organizer
            .from("negotiations")
            .select("id,status")
            .execute()
            .value
        XCTAssertTrue(visible.isEmpty, "organizer must not read any negotiation row")

        let pendingCount: Int = try await organizer
            .rpc("fn_get_pending_negotiation_count", params: ["p_event_id": DemoFixture.eventId.uuidString])
            .execute()
            .value
        XCTAssertEqual(pendingCount, 1)

        let responseCount: Int = try await organizer
            .rpc("fn_get_response_count", params: ["p_event_id": DemoFixture.eventId.uuidString])
            .execute()
            .value
        XCTAssertEqual(responseCount, 10)
    }

    // MARK: - RPC helpers

    private func recompute(
        _ client: SupabaseClient,
        eventId: UUID = DemoFixture.eventId
    ) async throws -> FeasibilityRun {
        try await client
            .rpc("fn_recompute_feasibility", params: ["p_event_id": eventId.uuidString])
            .execute()
            .value
    }

    private func propose(
        _ client: SupabaseClient,
        eventId: UUID = DemoFixture.eventId
    ) async throws -> UUID? {
        let data = try await client
            .rpc("fn_propose_relaxation", params: ["p_event_id": eventId.uuidString])
            .execute()
            .data
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\"\n"))
        return raw == "null" ? nil : UUID(uuidString: raw)
    }

    private func respond(
        _ client: SupabaseClient,
        negotiationId: UUID,
        accept: Bool
    ) async throws -> FeasibilityRun {
        try await client
            .rpc("fn_respond_negotiation", params: RespondParams(
                p_negotiation_id: negotiationId,
                p_accept: accept
            ))
            .execute()
            .value
    }

    // MARK: - Wire types

    private struct RespondParams: Encodable {
        let p_negotiation_id: UUID
        let p_accept: Bool
    }

    private struct FeasibilityRun: Decodable {
        let runId: UUID
        let feasibleCount: Int

        enum CodingKeys: String, CodingKey {
            case runId = "run_id"
            case feasibleCount = "feasible_count"
        }
    }

    private struct CreatedEvent: Decodable {
        let eventId: UUID
        let inviteCode: String

        enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case inviteCode = "invite_code"
        }
    }

    private struct CreateEventParams: Encodable {
        let p_name: String
        let p_display_name: String
        let p_travel_reference: String
        let p_travel_reference_place_id: String?
        let p_objective: String
    }

    private struct PendingRow: Decodable {
        let id: UUID
        let status: String
    }

    private struct ScoreRow: Decodable {
        let restaurantPlaceId: String
        let label: String?

        enum CodingKeys: String, CodingKey {
            case restaurantPlaceId = "restaurant_place_id"
            case label
        }
    }

    private struct ConstraintRow: Decodable {
        let id: UUID
        let normalizedType: String

        enum CodingKeys: String, CodingKey {
            case id
            case normalizedType = "normalized_type"
        }
    }

    private struct ConstraintInsert: Encodable {
        let eventId: UUID
        let participantId: UUID
        let kind = "MUST"
        let rawText: String
        let normalizedType = "allergy"
        let normalizedValue: [String: String]
        let visibility = "ANONYMOUS"

        enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case participantId = "participant_id"
            case kind
            case rawText = "raw_text"
            case normalizedType = "normalized_type"
            case normalizedValue = "normalized_value"
            case visibility
        }
    }
}
