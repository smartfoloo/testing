import Foundation

enum RecommendationLabel: String, Codable {
    case fairest
    case bestAccess = "best_access"
    case bestValue = "best_value"
    case bestExperience = "best_experience"
    case crowdPleaser = "crowd_pleaser"

    var badge: String {
        AppCopy.recommendation(self)
    }
}

struct RecommendationRun: Codable, Identifiable, Hashable {
    let id: UUID
    let eventId: UUID
    let runAt: Date
    let feasibleCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case runAt = "run_at"
        case feasibleCount = "feasible_count"
    }
}

struct RecommendationScore: Codable, Identifiable, Hashable {
    let id: UUID
    let runId: UUID
    let restaurantPlaceId: String
    let fairnessScore: Double?
    let satisfactionScore: Double?
    let qualityScore: Double?
    let label: RecommendationLabel?
    let explanation: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case restaurantPlaceId = "restaurant_place_id"
        case fairnessScore = "fairness_score"
        case satisfactionScore = "satisfaction_score"
        case qualityScore = "quality_score"
        case label
        case explanation
    }
}

struct RestaurantFeature: Codable, Identifiable, Hashable {
    let placeId: String
    let name: String?
    let priceYenEstimate: Int?
    let roomType: String?
    let cuisineTags: [String]
    let atmosphereTags: [String]

    var id: String { placeId }

    var roomDescription: String? {
        roomType.flatMap(AppCopy.room)
    }

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name
        case priceYenEstimate = "price_yen_estimate"
        case roomType = "room_type"
        case cuisineTags = "cuisine_tags"
        case atmosphereTags = "atmosphere_tags"
    }
}

/// `run_updated` broadcast payload from the `trg_broadcast_run` trigger.
struct RunUpdate: Codable, Hashable {
    let runId: UUID
    let feasibleCount: Int

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case feasibleCount = "feasible_count"
    }
}
