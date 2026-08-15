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
    /// Plain-language rendering of the one-step relaxation being proposed, e.g.
    /// "Would you accept a semi-private room instead of fully private?".
    var question: String {
        switch constraint.normalizedType {
        case .room:
            let proposed = proposedValue["room"]?.displayText.replacingOccurrences(of: "_", with: "-") ?? "different"
            let current = constraint.normalizedValue["room"]?.displayText ?? "your current"
            return "Would you accept a \(proposed) room instead of \(current)?"
        case .travelTime:
            let proposed = proposedValue["max_minutes"]?.displayText ?? "a longer"
            return "Would you accept a trip of up to \(proposed) minutes?"
        case .budget:
            let proposed = proposedValue["max_yen"]?.displayText ?? "a higher"
            return "Would you accept a budget of up to ¥\(proposed)?"
        default:
            let proposed = ConstraintFormatter.summary(
                type: constraint.normalizedType,
                value: proposedValue
            )
            return "Would you accept this change — \(proposed)?"
        }
    }

    var impact: String {
        unlockedCount == 1
            ? "This would unlock 1 more option."
            : "This would unlock \(unlockedCount) more options."
    }
}
