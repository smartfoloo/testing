import Foundation

enum RecommendationLabel: String, Codable {
    case fairest
    case bestAccess = "best_access"
    case bestValue = "best_value"
    case bestExperience = "best_experience"
    case crowdPleaser = "crowd_pleaser"

    var badge: String {
        AppCopy.recommendationBadge(self)
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

/// The dimensions the ordering score is built from (0016_scoring_and_objective.sql).
/// All six are normalized to 0..1 where **higher is better**, so the objective weights
/// can simply be a weighted sum. Burdens (the inverse) are stored separately.
enum ScoreDimension: String, Codable, CaseIterable, Identifiable {
    case travelFairness = "travel_fairness"
    case travelAccess = "travel_access"
    case satisfaction
    case quality
    case costFit = "cost_fit"
    case accessibilityFit = "accessibility_fit"

    var id: String { rawValue }

    var label: String { AppCopy.scoreDimension(self) }
}

/// Which quality signal was actually available for a venue. `ratingBayesianShrunk` is the
/// real signal; `atmosphereTagProxy` is the tag-richness stand-in used when the provider
/// gave us no rating, and it is deliberately capped below any real rating.
enum QualityMethod: String, Codable {
    case ratingBayesianShrunk = "rating_bayesian_shrunk"
    case atmosphereTagProxy = "atmosphere_tag_proxy"
}

/// `recommendation_scores.score_breakdown`. PRD §9: never present one opaque universal
/// score — every component, the weights that were applied to it, and the provenance of the
/// quality signal are stored so the UI can show the arithmetic.
///
/// Decoding is deliberately forgiving: every member is defaulted, because a breakdown
/// written by a newer engine version may carry keys this build does not know and may omit
/// keys it does. A single unexpected shape must never cost the whole shortlist.
struct ScoreBreakdown: Codable, Hashable {
    /// Reading instructions for the numbers below, so no caller has to guess a direction.
    struct Scale: Codable, Hashable {
        var components: String = ""
        var burdens: String = ""

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            components = try container.decodeIfPresent(String.self, forKey: .components) ?? ""
            burdens = try container.decodeIfPresent(String.self, forKey: .burdens) ?? ""
        }

        init(components: String = "", burdens: String = "") {
            self.components = components
            self.burdens = burdens
        }
    }

    struct Travel: Codable, Hashable {
        var participants: Int = 0
        var known: Int = 0
        var spreadMinutes: Double = 0
        var averageMinutes: Double?
        var complete: Bool = false
        var fairness: Double = 0
        var access: Double = 0

        enum CodingKeys: String, CodingKey {
            case participants
            case known
            case spreadMinutes = "spread_minutes"
            case averageMinutes = "average_minutes"
            case complete
            case fairness
            case access
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            participants = try container.decodeIfPresent(Int.self, forKey: .participants) ?? 0
            known = try container.decodeIfPresent(Int.self, forKey: .known) ?? 0
            spreadMinutes = try container.decodeIfPresent(Double.self, forKey: .spreadMinutes) ?? 0
            averageMinutes = try container.decodeIfPresent(Double.self, forKey: .averageMinutes)
            complete = try container.decodeIfPresent(Bool.self, forKey: .complete) ?? false
            fairness = try container.decodeIfPresent(Double.self, forKey: .fairness) ?? 0
            access = try container.decodeIfPresent(Double.self, forKey: .access) ?? 0
        }

        init() {}
    }

    struct Quality: Codable, Hashable {
        var score: Double = 0
        /// Raw wire value, so an unknown future method cannot fail the decode.
        var methodRaw: String = ""
        var rating: Double?
        var userRatingCount: Int?
        var priorRating: Double = 0
        var priorReviews: Int = 0
        var atmosphereTags: Int = 0

        var method: QualityMethod? { QualityMethod(rawValue: methodRaw) }

        enum CodingKeys: String, CodingKey {
            case score
            case methodRaw = "method"
            case rating
            case userRatingCount = "user_rating_count"
            case priorRating = "prior_rating"
            case priorReviews = "prior_reviews"
            case atmosphereTags = "atmosphere_tags"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            score = try container.decodeIfPresent(Double.self, forKey: .score) ?? 0
            methodRaw = try container.decodeIfPresent(String.self, forKey: .methodRaw) ?? ""
            rating = try container.decodeIfPresent(Double.self, forKey: .rating)
            userRatingCount = try container.decodeIfPresent(Int.self, forKey: .userRatingCount)
            priorRating = try container.decodeIfPresent(Double.self, forKey: .priorRating) ?? 0
            priorReviews = try container.decodeIfPresent(Int.self, forKey: .priorReviews) ?? 0
            atmosphereTags = try container.decodeIfPresent(Int.self, forKey: .atmosphereTags) ?? 0
        }

        init() {}
    }

    struct Cost: Codable, Hashable {
        /// 0..1, higher = more disproportionate cost burden (the inverse of `cost_fit`).
        var burden: Double = 0
        var priceYen: Int?
        var tightestBudgetYen: Int?
        var budgetMusts: Int = 0
        var referenceYen: Int = 0

        enum CodingKeys: String, CodingKey {
            case burden
            case priceYen = "price_yen"
            case tightestBudgetYen = "tightest_budget_yen"
            case budgetMusts = "budget_musts"
            case referenceYen = "reference_yen"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            burden = try container.decodeIfPresent(Double.self, forKey: .burden) ?? 0
            priceYen = try container.decodeIfPresent(Int.self, forKey: .priceYen)
            tightestBudgetYen = try container.decodeIfPresent(Int.self, forKey: .tightestBudgetYen)
            budgetMusts = try container.decodeIfPresent(Int.self, forKey: .budgetMusts) ?? 0
            referenceYen = try container.decodeIfPresent(Int.self, forKey: .referenceYen) ?? 0
        }

        init() {}
    }

    struct Accessibility: Codable, Hashable {
        /// 0..1, higher = more unmet/unknown accessibility needs (inverse of `accessibility_fit`).
        var burden: Double = 0
        var needs: [String] = []
        var unmetNeeds: [String] = []
        var venueTags: [String] = []
        var dataPresent: Bool = false
        var requests: Int = 0

        enum CodingKeys: String, CodingKey {
            case burden
            case needs
            case unmetNeeds = "unmet_needs"
            case venueTags = "venue_tags"
            case dataPresent = "data_present"
            case requests
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            burden = try container.decodeIfPresent(Double.self, forKey: .burden) ?? 0
            needs = try container.decodeIfPresent([String].self, forKey: .needs) ?? []
            unmetNeeds = try container.decodeIfPresent([String].self, forKey: .unmetNeeds) ?? []
            venueTags = try container.decodeIfPresent([String].self, forKey: .venueTags) ?? []
            dataPresent = try container.decodeIfPresent(Bool.self, forKey: .dataPresent) ?? false
            requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        }

        init() {}
    }

    var version: Int = 0
    var objective: EventObjective = .balanced
    var scale = Scale()
    /// Keyed by `ScoreDimension.rawValue`; read through `weight(for:)` and friends, which
    /// answer nil for a dimension the stored breakdown does not mention.
    var weights: [String: Double] = [:]
    var components: [String: Double] = [:]
    /// `weights[dimension] * components[dimension]`, i.e. what each dimension contributed.
    var contributions: [String: Double] = [:]
    var objectiveScore: Double?
    var travel = Travel()
    var quality = Quality()
    var cost = Cost()
    var accessibility = Accessibility()

    enum CodingKeys: String, CodingKey {
        case version
        case objective
        case scale
        case weights
        case components
        case contributions
        case objectiveScore = "objective_score"
        case travel
        case quality
        case cost
        case accessibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        let rawObjective = try container.decodeIfPresent(String.self, forKey: .objective)
        objective = rawObjective.flatMap(EventObjective.init(rawValue:)) ?? .balanced
        scale = try container.decodeIfPresent(Scale.self, forKey: .scale) ?? Scale()
        // Decoded as optional values and then dropped: a null inside the map is a dimension
        // the engine could not score, which must read as absent rather than fail the row.
        weights = Self.numbers(try container.decodeIfPresent([String: Double?].self, forKey: .weights))
        components = Self.numbers(try container.decodeIfPresent([String: Double?].self, forKey: .components))
        contributions = Self.numbers(try container.decodeIfPresent([String: Double?].self, forKey: .contributions))
        objectiveScore = try container.decodeIfPresent(Double.self, forKey: .objectiveScore)
        travel = try container.decodeIfPresent(Travel.self, forKey: .travel) ?? Travel()
        quality = try container.decodeIfPresent(Quality.self, forKey: .quality) ?? Quality()
        cost = try container.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        accessibility = try container.decodeIfPresent(Accessibility.self, forKey: .accessibility) ?? Accessibility()
    }

    init() {}

    // MARK: - Reading the stored arithmetic

    private static func numbers(_ raw: [String: Double?]?) -> [String: Double] {
        (raw ?? [:]).compactMapValues { $0 }
    }

    /// Only finite stored numbers are readings; anything else is a gap, not a zero.
    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    func component(for dimension: ScoreDimension) -> Double? {
        Self.finite(components[dimension.rawValue])
    }

    func weight(for dimension: ScoreDimension) -> Double? {
        Self.finite(weights[dimension.rawValue])
    }

    func contribution(for dimension: ScoreDimension) -> Double? {
        Self.finite(contributions[dimension.rawValue])
    }

    /// True when the stored number is a placeholder for data we never got, not a
    /// measurement. `fn_banded_score` keeps those below 0.2 so they cannot outrank
    /// measured data, which means showing them as a plain low percentage would read as
    /// "this venue is bad".
    func isUnknown(_ dimension: ScoreDimension) -> Bool {
        switch dimension {
        case .travelFairness, .travelAccess:
            return !travel.complete || travel.known == 0
        case .quality:
            return quality.method == .atmosphereTagProxy
        case .costFit:
            // An unknown price is scored as the worst case, so it is a gap, not a measurement.
            return cost.priceYen == nil
        case .accessibilityFit:
            // With no request there is nothing to verify; the gap only matters if someone asked.
            return !accessibility.dataPresent && accessibility.requests > 0
        case .satisfaction:
            return false
        }
    }

    /// Which dimensions this event's objective actually leans on: the ones weighted above
    /// an even split. `fn_objective_weights` always has a peak, so this never comes back
    /// empty — unless the weights are missing entirely, which only legacy rows can be.
    var emphasizedDimensions: [ScoreDimension] {
        let evenShare = 1.0 / Double(ScoreDimension.allCases.count)
        let above = ScoreDimension.allCases.filter { (weight(for: $0) ?? 0) > evenShare }
        let chosen: [ScoreDimension]
        if above.isEmpty {
            let peak = ScoreDimension.allCases.compactMap { weight(for: $0) }.max()
            guard let peak else { return [] }
            chosen = ScoreDimension.allCases.filter { weight(for: $0) == peak }
        } else {
            chosen = above
        }
        return chosen.sorted { (weight(for: $0) ?? 0) > (weight(for: $1) ?? 0) }
    }
}

struct RecommendationScore: Codable, Identifiable, Hashable {
    let id: UUID
    let runId: UUID
    let restaurantPlaceId: String
    let fairnessScore: Double?
    let satisfactionScore: Double?
    let qualityScore: Double?
    /// 0..1, higher = more disproportionate cost burden (the inverse of `cost_fit`).
    let costBurdenScore: Double?
    /// 0..1, higher = more unmet/unknown accessibility needs (inverse of `accessibility_fit`).
    let accessibilityBurdenScore: Double?
    /// The objective-weighted composite the cards are ordered by.
    let objectiveScore: Double?
    let scoreBreakdown: ScoreBreakdown?
    /// Nil is legitimate: 0016 only labels a row that genuinely earned the label, and
    /// `AppCopy.recommendationBadge(nil)` renders 「おすすめ」 for the rest.
    let label: RecommendationLabel?
    let explanation: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case restaurantPlaceId = "restaurant_place_id"
        case fairnessScore = "fairness_score"
        case satisfactionScore = "satisfaction_score"
        case qualityScore = "quality_score"
        case costBurdenScore = "cost_burden_score"
        case accessibilityBurdenScore = "accessibility_burden_score"
        case objectiveScore = "objective_score"
        case scoreBreakdown = "score_breakdown"
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
