import Foundation

enum ConstraintKind: String, Codable, CaseIterable, Identifiable {
    case must = "MUST"
    case want = "WANT"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .must: return AppCopy.must
        case .want: return AppCopy.want
        }
    }
}

enum NormalizedType: String, Codable, CaseIterable, Identifiable {
    case budget
    case cuisine
    case dietary
    case allergy
    case smoking
    case room
    case travelTime = "travel_time"
    case accessibility
    case atmosphere
    case other

    var id: String { rawValue }

    var label: String { AppCopy.normalizedType(self) }
}

enum ConstraintVisibility: String, Codable, CaseIterable, Identifiable {
    case publicToGroup = "PUBLIC"
    case anonymous = "ANONYMOUS"
    case privateToSelf = "PRIVATE"

    var id: String { rawValue }

    var label: String { AppCopy.visibility(self) }
}

/// How sensitive a requirement is. Advisory metadata assigned server-side from
/// `normalized_type` (0018's trigger): it drives presentation and logging care, and it must
/// never override `visibility`, which stays the participant's own decision (PRD §5).
enum ConstraintSensitivity: String, Codable {
    case normal
    case sensitive
    case highlySensitive = "highly_sensitive"
}

/// Whether a MUST needs external confirmation before it can be trusted (PRD §11:
/// "Unknown ≠ supported"). P0 records the requirement only — `required` is the hook the P1
/// "needs confirmation" badge will use; nothing renders it yet.
enum VerificationRequirement: String, Codable {
    case none
    case recommended
    case required
}

/// Response of the `llm-assist` Edge Function in `parse` mode.
struct ParseResult: Codable, Hashable {
    var normalizedType: NormalizedType
    var normalizedValue: [String: JSONValue]
    var suggestedVisibility: ConstraintVisibility
    var confidence: Double
    var needsClarification: Bool
    /// The participant's own wording the structured taxonomy did not capture. Kept so P1
    /// semantic matching has something to embed; it is verbatim human text, so it never
    /// reaches the sanitized feed.
    var semanticRemainder: String?
    /// Both of these are decided server-side and forced by a BEFORE-INSERT trigger, so the
    /// client only reads them — and reads them as raw strings, so a value added to the
    /// taxonomy later cannot fail the decode of an otherwise usable parse.
    var sensitivityRaw: String?
    var verificationRequirementRaw: String?

    var sensitivity: ConstraintSensitivity? {
        sensitivityRaw.flatMap(ConstraintSensitivity.init(rawValue:))
    }

    var verificationRequirement: VerificationRequirement? {
        verificationRequirementRaw.flatMap(VerificationRequirement.init(rawValue:))
    }

    enum CodingKeys: String, CodingKey {
        case normalizedType = "normalized_type"
        case normalizedValue = "normalized_value"
        case suggestedVisibility = "suggested_visibility"
        case confidence
        case needsClarification = "needs_clarification"
        case semanticRemainder = "semantic_remainder"
        case sensitivityRaw = "sensitivity"
        case verificationRequirementRaw = "verification_requirement"
    }
}

/// A row of the sanitized group feed: either from `fn_get_sanitized_feed` or a broadcast payload.
/// `displayName` is nil for ANONYMOUS entries — the name is stripped server-side, not hidden here.
struct FeedItem: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: ConstraintKind
    let normalizedType: NormalizedType
    let normalizedValue: [String: JSONValue]
    let visibility: ConstraintVisibility
    let displayName: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case normalizedType = "normalized_type"
        case normalizedValue = "normalized_value"
        case visibility
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

extension JSONValue {
    var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "はい" : "いいえ"
        case .array(let values): return values.map(\.displayText).joined(separator: ", ")
        case .object(let values): return values.map { "\($0.key): \($0.value.displayText)" }.joined(separator: ", ")
        case .null: return "—"
        }
    }

    /// The members of a tag-style value, kept separate so each can be labelled on its own —
    /// `displayText` above would hand back one 「quiet, lively」 string. A single stored string
    /// counts as a one-member list; anything else has no members, which is what the callers
    /// already treat as "nothing stated". Mirrors `tagList` in web/src/models/format.ts.
    var tagList: [String] {
        switch self {
        case .array(let values):
            return values
                .map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        default:
            return []
        }
    }
}

enum ConstraintFormatter {
    static func summary(type: NormalizedType, value: [String: JSONValue]) -> String {
        guard !value.isEmpty else { return type.label }
        switch type {
        case .room:
            if let room = value["room"]?.displayText, let label = AppCopy.room(room) {
                return "\(type.label)：\(label)"
            }
        case .budget:
            if let amount = value["max_yen"]?.displayText { return "\(type.label)：\(amount)円まで" }
        case .travelTime:
            if let minutes = value["max_minutes"]?.displayText { return "\(type.label)：\(minutes)分以内" }
        case .cuisine:
            let include = value["include"]?.tagList ?? []
            if !include.isEmpty { return "\(type.label)：\(labelled(include, AppCopy.cuisine))" }
        // dietary and atmosphere share the {"tags": []} shape but not the vocabulary, so they
        // no longer share a branch.
        case .dietary:
            let tags = value["tags"]?.tagList ?? []
            if !tags.isEmpty { return "\(type.label)：\(labelled(tags, AppCopy.dietary))" }
        case .atmosphere:
            let tags = value["tags"]?.tagList ?? []
            if !tags.isEmpty { return "\(type.label)：\(labelled(tags, AppCopy.atmosphere))" }
        case .allergy:
            let allergens = value["allergens"]?.tagList ?? []
            if !allergens.isEmpty { return "\(type.label)：\(labelled(allergens, AppCopy.allergen))" }
        default: break
        }
        return "\(type.label)：\(value.values.map(\.displayText).joined(separator: "、"))"
    }

    /// Japanese labels for a tag list, falling back to the tag exactly as stored when the
    /// vocabulary does not know it. Unknown tags are printed, never dropped and never guessed
    /// at: an allergy or dietary tag that vanished would be a safety problem, and an invented
    /// translation would be worse than the English. Mirrors `labelTags` in
    /// web/src/models/format.ts.
    private static func labelled(_ tags: [String], _ label: (String) -> String?) -> String {
        tags.map { label($0) ?? $0 }.joined(separator: "・")
    }

    static func feedLine(_ item: FeedItem) -> String {
        let who = item.displayName ?? "匿名の参加者"
        let prefix = item.kind == .must ? "絶対に必要" : "できれば欲しい"
        return "\(who)｜\(prefix)：\(summary(type: item.normalizedType, value: item.normalizedValue))"
    }
}
