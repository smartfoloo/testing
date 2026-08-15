import Foundation

enum ConstraintKind: String, Codable, CaseIterable, Identifiable {
    case must = "MUST"
    case want = "WANT"

    var id: String { rawValue }
    var title: String { rawValue }
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

    var label: String {
        switch self {
        case .travelTime: return "Travel time"
        default: return rawValue.capitalized
        }
    }
}

enum ConstraintVisibility: String, Codable, CaseIterable, Identifiable {
    case publicToGroup = "PUBLIC"
    case anonymous = "ANONYMOUS"
    case privateToSelf = "PRIVATE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .publicToGroup: return "Group"
        case .anonymous: return "Anonymous"
        case .privateToSelf: return "Private"
        }
    }
}

/// Response of the `llm-assist` Edge Function in `parse` mode.
struct ParseResult: Codable, Hashable {
    var normalizedType: NormalizedType
    var normalizedValue: [String: JSONValue]
    var suggestedVisibility: ConstraintVisibility
    var confidence: Double
    var needsClarification: Bool

    enum CodingKeys: String, CodingKey {
        case normalizedType = "normalized_type"
        case normalizedValue = "normalized_value"
        case suggestedVisibility = "suggested_visibility"
        case confidence
        case needsClarification = "needs_clarification"
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
        case .bool(let value): return value ? "yes" : "no"
        case .array(let values): return values.map(\.displayText).joined(separator: ", ")
        case .object(let values): return values.map { "\($0.key): \($0.value.displayText)" }.joined(separator: ", ")
        case .null: return "—"
        }
    }
}

enum ConstraintFormatter {
    /// Human summary of a normalized constraint, e.g. "Budget: max yen 4000".
    static func summary(type: NormalizedType, value: [String: JSONValue]) -> String {
        guard !value.isEmpty else { return type.label }
        let details = value
            .sorted { $0.key < $1.key }
            .map { "\($0.key.replacingOccurrences(of: "_", with: " ")) \($0.value.displayText)" }
            .joined(separator: ", ")
        return "\(type.label): \(details)"
    }

    static func feedLine(_ item: FeedItem) -> String {
        let who = item.displayName ?? "Someone"
        let verb = item.kind == .must ? "requires" : "would like"
        return "\(who) \(verb): \(summary(type: item.normalizedType, value: item.normalizedValue))"
    }
}
