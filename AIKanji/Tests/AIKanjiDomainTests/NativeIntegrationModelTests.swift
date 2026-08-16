import Foundation
@testable import AIKanji
import XCTest

final class NativeIntegrationModelTests: XCTestCase {
    func testMemberEventDecodesMergedHistoryAndRunFields() throws {
        let data = Data("""
        {
          "event_id":"00000000-0000-0000-0000-000000000001",
          "name":"Dinner",
          "invite_code":"abc123",
          "status":"ready",
          "scheduled_at":"2030-01-02T10:30:00Z",
          "participant_id":"00000000-0000-0000-0000-000000000002",
          "role":"participant",
          "participant_count":4,
          "completed_count":3,
          "input_completed":true,
          "latest_run_id":"00000000-0000-0000-0000-000000000003",
          "latest_run_at":"2030-01-02T09:30:00Z",
          "feasible_count":2,
          "chosen_place_id":null,
          "chosen_at":null
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(MemberEvent.self, from: data)
        XCTAssertEqual(event.scheduledAt, ISO8601DateFormatter().date(from: "2030-01-02T10:30:00Z"))
        XCTAssertEqual(event.latestRunId, UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        XCTAssertEqual(event.feasibleCount, 2)
    }

    func testSavedConstraintDecodesServerOwnedMetadataAndTimestamps() throws {
        let data = Data("""
        {
          "id":"00000000-0000-0000-0000-000000000004",
          "kind":"MUST",
          "raw_text":"卵アレルギー",
          "normalized_type":"allergy",
          "normalized_value":{"allergens":["egg"]},
          "visibility":"PRIVATE",
          "sensitivity":"highly_sensitive",
          "verification_requirement":"required",
          "semantic_remainder":"店舗に直接確認",
          "created_at":"2030-01-02T09:00:00Z",
          "updated_at":"2030-01-02T09:05:00Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let constraint = try decoder.decode(ConstraintService.SavedConstraint.self, from: data)
        XCTAssertEqual(constraint.sensitivity, .highlySensitive)
        XCTAssertEqual(constraint.verificationRequirement, .required)
        XCTAssertEqual(constraint.semanticRemainder, "店舗に直接確認")
        XCTAssertGreaterThan(constraint.updatedAt, constraint.createdAt)
    }

    func testRunUpdateRequiresAuthoritativeRunTimestamp() throws {
        let data = Data("""
        {"run_id":"00000000-0000-0000-0000-000000000005","feasible_count":3,"run_at":"2030-01-02T09:30:00Z"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let update = try decoder.decode(RunUpdate.self, from: data)
        XCTAssertEqual(update.feasibleCount, 3)
        XCTAssertEqual(update.runAt, ISO8601DateFormatter().date(from: "2030-01-02T09:30:00Z"))
    }

    func testOfficialAllergenSelectionsUseCanonicalKeysAndFailClosedWhenUnsupported() {
        XCTAssertEqual(
            ConstraintCatalog.canonicalAllergens(for: ["shrimp", "crab", "egg"]),
            ["crab", "egg", "shrimp"]
        )
        XCTAssertEqual(ConstraintCatalog.canonicalAllergens(for: ["egg", "mango"]), [])
        XCTAssertEqual(ConstraintCatalog.unsupportedAllergenLabels(for: ["egg", "mango"]), ["mango"])
        XCTAssertEqual(ConstraintCatalog.mandatoryAllergens.count, 9)
        XCTAssertEqual(ConstraintCatalog.recommendedAllergens.count, 20)
    }

    func testParserPreservesEveryValidNonStructuredTypeAndCompatibleKind() throws {
        for (rawType, expectedType, expectedKind) in [
            ("accessibility", NormalizedType.accessibility, ConstraintKind.must),
            ("smoking", .smoking, .must),
            ("atmosphere", .atmosphere, .want),
        ] {
            let data = Data("""
            {
              "normalized_type":"\(rawType)",
              "normalized_value":{},
              "suggested_visibility":"PRIVATE",
              "confidence":0.9,
              "needs_clarification":true,
              "semantic_remainder":"original wording"
            }
            """.utf8)
            let result = try JSONDecoder().decode(ParseResult.self, from: data)
            XCTAssertEqual(result.normalizedType, expectedType)
            XCTAssertEqual(result.normalizedType.compatibleKind, expectedKind)
            XCTAssertTrue(ConstraintCatalog.normalizedTypes.contains(expectedType))
            XCTAssertFalse(ConstraintCatalog.structuredCategories.contains(expectedType))
        }
        XCTAssertEqual(NormalizedType.budget.compatibleKind, .must)
        XCTAssertEqual(NormalizedType.room.compatibleKind, .must)
        XCTAssertEqual(NormalizedType.dietary.compatibleKind, .must)
        XCTAssertEqual(NormalizedType.allergy.compatibleKind, .must)
        XCTAssertEqual(NormalizedType.travelTime.compatibleKind, .must)
        XCTAssertEqual(NormalizedType.cuisine.compatibleKind, .want)
        XCTAssertEqual(NormalizedType.other.compatibleKind, .want)
    }

    func testProviderQualityProvenanceDecodesAndLegacyMethodFallsBack() throws {
        let data = Data("""
        {
          "score":0.72,
          "method":"google_and_tabelog",
          "rating":4.4,
          "user_rating_count":120,
          "prior_rating":4.0,
          "prior_reviews":20,
          "atmosphere_tags":3,
          "google_shrunk":4.31,
          "google_percentile":0.75,
          "google_ranked_candidates":8,
          "tabelog_rating":3.52,
          "tabelog_review_count":240,
          "tabelog_prior_rating":3.2,
          "tabelog_shrunk":3.49,
          "tabelog_percentile":0.69,
          "tabelog_ranked_candidates":6,
          "blended_percentile":0.72
        }
        """.utf8)
        let quality = try JSONDecoder().decode(ScoreBreakdown.Quality.self, from: data)
        XCTAssertEqual(quality.method, .googleAndTabelog)
        XCTAssertEqual(quality.googleRankedCandidates, 8)
        XCTAssertEqual(quality.tabelogRating, 3.52)
        XCTAssertEqual(quality.tabelogReviewCount, 240)
        XCTAssertEqual(quality.blendedPercentile, 0.72)
        var breakdown = ScoreBreakdown()
        breakdown.quality = quality
        let evidence = AppCopy.scoreDimensionEvidence(breakdown, .quality)
        XCTAssertTrue(evidence.contains("Google"))
        XCTAssertTrue(evidence.contains("食べログ"))

        let legacy = try JSONDecoder().decode(
            ScoreBreakdown.Quality.self,
            from: Data("{\"method\":\"rating_bayesian_shrunk\"}".utf8)
        )
        XCTAssertEqual(legacy.method, .googleOnly)
    }

    func testRunOrderingUsesTimestampThenRunID() {
        let date = Date(timeIntervalSince1970: 1_000)
        let older = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let newer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        XCTAssertTrue(RunOrdering.isNewer(runAt: date, runId: newer, than: date, currentRunId: older))
        XCTAssertFalse(RunOrdering.isNewer(runAt: date, runId: older, than: date, currentRunId: newer))
        XCTAssertTrue(RunOrdering.isNewer(runAt: date.addingTimeInterval(1), runId: older, than: date, currentRunId: newer))
    }

    func testFeasibilityStalenessRequiresStrictlyNewerRequirementStamp() {
        let runAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(FeasibilityStaleness.isUncounted(
            staleAt: runAt.addingTimeInterval(1),
            computedThrough: runAt
        ))
        XCTAssertFalse(FeasibilityStaleness.isUncounted(staleAt: runAt, computedThrough: runAt))
        XCTAssertFalse(FeasibilityStaleness.isUncounted(
            staleAt: runAt.addingTimeInterval(-1),
            computedThrough: runAt
        ))
        XCTAssertTrue(FeasibilityStaleness.isUncounted(staleAt: runAt, computedThrough: nil))
    }

    func testDecisionOrderingRejectsStaleSnapshotsAndSupportsAuthoritativeLegacyRows() {
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = oldDate.addingTimeInterval(1)
        let old = EventDecision(chosenPlaceId: "old", chosenAt: oldDate)
        let new = EventDecision(chosenPlaceId: "new", chosenAt: newDate)
        XCTAssertTrue(EventDecisionOrdering.isNewer(new, than: old))
        XCTAssertFalse(EventDecisionOrdering.isNewer(old, than: new))
        XCTAssertFalse(EventDecisionOrdering.isNewer(
            EventDecision(chosenPlaceId: "legacy", chosenAt: nil),
            than: new
        ))
        XCTAssertTrue(EventDecisionOrdering.isNewer(
            EventDecision(chosenPlaceId: "a", chosenAt: nil),
            than: EventDecision(chosenPlaceId: "z", chosenAt: nil),
            authoritativeLegacy: true
        ))
    }

    func testInviteSharePrefersConfiguredLink() {
        let base = URL(string: "https://example.com/invite")!
        XCTAssertEqual(InviteLink.url(code: "abc123", base: base)?.absoluteString, "https://example.com/?code=abc123")
    }
}
