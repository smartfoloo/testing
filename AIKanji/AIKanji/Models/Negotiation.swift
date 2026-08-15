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
    /// Candidates whose ONLY unmet MUSTs are accessibility ones (0022) — the venues a single
    /// phone call away. Accessibility is deliberately never relaxable, so without this the
    /// group would see a bare 0 with no way to understand or act on it. Optional because a
    /// run recorded before 0022 does not carry the key.
    let accessibilityUnverifiedCount: Int?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case feasibleCount = "feasible_count"
        case accessibilityUnverifiedCount = "accessibility_unverified_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try container.decodeIfPresent(UUID.self, forKey: .runId)
        feasibleCount = try container.decode(Int.self, forKey: .feasibleCount)
        accessibilityUnverifiedCount = try container.decodeIfPresent(
            Int.self, forKey: .accessibilityUnverifiedCount
        )
    }
}

extension PendingNegotiation {
    var question: String {
        switch constraint.normalizedType {
        case .room:
            // 0022 made this step composite: widen 個室 → 半個室 AND accept venues whose room
            // type no provider could confirm. Asking someone to agree to something the
            // question did not mention is exactly what this flow exists to prevent, so both
            // concessions are named. Mirrors negotiationQuestion in web/src/models/format.ts.
            let proposedRaw = proposedValue["room"]?.displayText
            let currentRaw = constraint.normalizedValue["room"]?.displayText
            let proposed = proposedRaw.flatMap { AppCopy.room($0) } ?? "別の席"
            let current = currentRaw.flatMap { AppCopy.room($0) } ?? "今の条件"
            let widened = proposedRaw != nil && currentRaw != nil && proposedRaw != currentRaw
            // JSONValue is this app's own enum (see Constraint.swift), so match the case
            // rather than reaching for a Supabase AnyJSON accessor that does not exist here.
            // Only a real JSON true counts, exactly as fn_jsonb_flag requires in SQL.
            var acceptsUnknown = false
            if case .bool(true) = proposedValue["accept_unknown"] { acceptsUnknown = true }
            if widened && acceptsUnknown {
                return "\(current)を\(proposed)に変更し、席のタイプが確認できていないお店も候補に含めてよいですか？"
            }
            if acceptsUnknown {
                return "\(current)かどうか確認できていないお店も、候補に含めてよいですか？"
            }
            return "\(current)を\(proposed)に変更しても大丈夫ですか？"
        case .smoking:
            // The smoking step never trades away the preference; it accepts venues whose
            // policy could not be confirmed. Without this case the generic fallback rendered
            // the raw enum: 「喫煙：non_smoking…に変更しても大丈夫ですか？」
            let current = constraint.normalizedValue["preference"]?.displayText
            let named = current.flatMap { AppCopy.smoking($0) } ?? "喫煙の条件"
            return "\(named)かどうか確認できていないお店も、候補に含めてよいですか？"
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
