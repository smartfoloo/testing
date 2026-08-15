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
        case .bool(let value): return value ? "はい" : "いいえ"
        case .array(let values): return values.map(\.displayText).joined(separator: ", ")
        case .object(let values): return values.map { "\($0.key): \($0.value.displayText)" }.joined(separator: ", ")
        case .null: return "—"
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
            if let include = value["include"]?.displayText, !include.isEmpty {
                return "\(type.label)：\(include)"
            }
        case .dietary, .atmosphere:
            if let tags = value["tags"]?.displayText, !tags.isEmpty { return "\(type.label)：\(tags)" }
        case .allergy:
            if let allergens = value["allergens"]?.displayText, !allergens.isEmpty {
                return "\(type.label)：\(allergens)"
            }
        default: break
        }
        return "\(type.label)：\(value.values.map(\.displayText).joined(separator: "、"))"
    }

    static func feedLine(_ item: FeedItem) -> String {
        let who = item.displayName ?? "匿名の参加者"
        let prefix = item.kind == .must ? "絶対に必要" : "できれば欲しい"
        return "\(who)｜\(prefix)：\(summary(type: item.normalizedType, value: item.normalizedValue))"
    }
}
