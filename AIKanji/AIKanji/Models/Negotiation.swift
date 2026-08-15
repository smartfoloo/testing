import Foundation

enum NegotiationStatus: String, Codable {
    case proposed = "PROPOSED"
    case accepted = "ACCEPTED"
    case rejected = "REJECTED"
}

/// A relaxation proposal as seen by the participant it targets. RLS returns only that
/// participant's own rows, and the embedded constraint is their own constraint — nobody
/// else, organizer included, can read either side of this.
struct PendingNegotiation: Codable, Identifiable, Hashable {
    let id: UUID
    let proposedValue: [String: JSONValue]
    let unlockedCount: Int
    let constraint: Constraint

    struct Constraint: Codable, Hashable {
        let normalizedType: NormalizedType
        let normalizedValue: [String: JSONValue]
        let rawText: String

        enum CodingKeys: String, CodingKey {
            case normalizedType = "normalized_type"
            case normalizedValue = "normalized_value"
            case rawText = "raw_text"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case proposedValue = "proposed_value"
        case unlockedCount = "unlocked_count"
        case constraint = "participant_constraints"
    }
}

/// Payload of `fn_recompute_feasibility` and `fn_respond_negotiation`.
struct FeasibilityResult: Codable, Hashable {
    let runId: UUID?
    let feasibleCount: Int

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case feasibleCount = "feasible_count"
    }
}

extension PendingNegotiation {
    var question: String {
        switch constraint.normalizedType {
        case .room:
            let proposed = proposedValue["room"].flatMap { AppCopy.room($0.displayText) } ?? "別の席"
            let current = constraint.normalizedValue["room"].flatMap { AppCopy.room($0.displayText) } ?? "今の条件"
            return "\(current)を\(proposed)に変更しても大丈夫ですか？"
        case .travelTime:
            let proposed = proposedValue["max_minutes"]?.displayText ?? "少し長い"
            return "移動時間を\(proposed)分以内に変更しても大丈夫ですか？"
        case .budget:
            let proposed = proposedValue["max_yen"]?.displayText ?? "少し高い"
            return "予算を\(proposed)円まで変更しても大丈夫ですか？"
        default:
            return "\(ConstraintFormatter.summary(type: constraint.normalizedType, value: proposedValue))に変更しても大丈夫ですか？"
        }
    }

    var impact: String {
        "\(unlockedCount)件のお店が候補に加わります。"
    }
}
