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

    var compatibleKind: ConstraintKind {
        switch self {
        case .budget, .dietary, .allergy, .smoking, .room, .travelTime, .accessibility:
            return .must
        case .cuisine, .atmosphere, .other:
            return .want
        }
    }
}

enum ConstraintVisibility: String, Codable, CaseIterable, Identifiable {
    case publicToGroup = "PUBLIC"
    case anonymous = "ANONYMOUS"
    case privateToSelf = "PRIVATE"

    var id: String { rawValue }

    var label: String { AppCopy.visibility(self) }
}

struct ConstraintOption: Identifiable, Hashable {
    let key: String
    let label: String
    let canonicalKey: String?

    init(key: String, label: String, canonicalKey: String? = nil) {
        self.key = key
        self.label = label
        self.canonicalKey = canonicalKey
    }

    var id: String { key }
}

enum ConstraintCatalog {
    static let structuredCategories: [NormalizedType] = [
        .budget, .cuisine, .allergy, .dietary, .room, .travelTime, .other,
    ]

    static let normalizedTypes = NormalizedType.allCases

    static let mandatoryAllergens: [ConstraintOption] = [
        .init(key: "shrimp", label: "えび", canonicalKey: "shrimp"),
        .init(key: "cashew_nut", label: "カシューナッツ", canonicalKey: "cashew_nut"),
        .init(key: "crab", label: "かに", canonicalKey: "crab"),
        .init(key: "walnut", label: "くるみ", canonicalKey: "walnut"),
        .init(key: "wheat", label: "小麦", canonicalKey: "wheat"),
        .init(key: "buckwheat", label: "そば", canonicalKey: "buckwheat"),
        .init(key: "egg", label: "卵", canonicalKey: "egg"),
        .init(key: "milk", label: "乳", canonicalKey: "milk"),
        .init(key: "peanut", label: "落花生（ピーナッツ）", canonicalKey: "peanut"),
    ]

    static let recommendedAllergens: [ConstraintOption] = [
        .init(key: "almond", label: "アーモンド", canonicalKey: "almond"),
        .init(key: "abalone", label: "あわび", canonicalKey: "abalone"),
        .init(key: "squid", label: "いか", canonicalKey: "squid"),
        .init(key: "salmon_roe", label: "いくら", canonicalKey: "salmon_roe"),
        .init(key: "orange", label: "オレンジ", canonicalKey: "orange"),
        .init(key: "kiwi", label: "キウイフルーツ", canonicalKey: "kiwi"),
        .init(key: "beef", label: "牛肉", canonicalKey: "beef"),
        .init(key: "sesame", label: "ごま", canonicalKey: "sesame"),
        .init(key: "salmon", label: "さけ", canonicalKey: "salmon"),
        .init(key: "mackerel", label: "さば", canonicalKey: "mackerel"),
        .init(key: "soybean", label: "大豆", canonicalKey: "soybean"),
        .init(key: "chicken", label: "鶏肉", canonicalKey: "chicken"),
        .init(key: "banana", label: "バナナ", canonicalKey: "banana"),
        .init(key: "pistachio", label: "ピスタチオ", canonicalKey: "pistachio"),
        .init(key: "pork", label: "豚肉", canonicalKey: "pork"),
        .init(key: "macadamia_nut", label: "マカダミアナッツ", canonicalKey: "macadamia_nut"),
        .init(key: "peach", label: "もも", canonicalKey: "peach"),
        .init(key: "yam", label: "やまいも", canonicalKey: "yam"),
        .init(key: "apple", label: "りんご", canonicalKey: "apple"),
        .init(key: "gelatin", label: "ゼラチン", canonicalKey: "gelatin"),
    ]

    static var allergens: [ConstraintOption] {
        mandatoryAllergens + recommendedAllergens
    }

    static let dietary: [ConstraintOption] = [
        .init(key: "vegetarian", label: "ベジタリアン"),
        .init(key: "vegan", label: "ヴィーガン"),
        .init(key: "halal", label: "ハラール"),
        .init(key: "gluten_free", label: "グルテンフリー"),
    ]

    static let cuisines: [ConstraintOption] = [
        .init(key: "japanese", label: "和食"),
        .init(key: "sushi", label: "寿司"),
        .init(key: "yakiniku", label: "焼肉"),
        .init(key: "izakaya", label: "居酒屋"),
        .init(key: "italian", label: "イタリアン"),
        .init(key: "french", label: "フレンチ"),
        .init(key: "chinese", label: "中華"),
        .init(key: "korean", label: "韓国料理"),
        .init(key: "curry", label: "カレー"),
        .init(key: "ramen", label: "ラーメン"),
    ]

    static let rooms: [ConstraintOption] = [
        .init(key: "private", label: "個室"),
        .init(key: "semi_private", label: "半個室"),
        .init(key: "open", label: "オープン席"),
    ]

    static func allergenLabel(for key: String) -> String {
        AppCopy.allergen(key) ?? allergens.first { $0.key == key }?.label ?? key
    }

    static func dietaryLabel(for key: String) -> String {
        dietary.first { $0.key == key }?.label ?? AppCopy.dietary(key) ?? key
    }

    static func canonicalAllergens(for selection: Set<String>) -> [String] {
        let knownKeys = Set(allergens.map(\.key))
        guard selection.isSubset(of: knownKeys) else { return [] }
        return Array(Set(allergens.filter { selection.contains($0.key) }.compactMap(\.canonicalKey))).sorted()
    }

    static func unsupportedAllergenLabels(for selection: Set<String>) -> [String] {
        let knownKeys = Set(allergens.map(\.key))
        return selection.subtracting(knownKeys).sorted()
    }

    static func selectedAllergenKeys(
        canonicalKeys: [String],
        rawText: String,
        semanticRemainder: String?
    ) -> Set<String> {
        let expanded = canonicalKeys.flatMap { $0 == "shellfish" ? ["shrimp", "crab"] : [$0] }
        let wording = rawText + " " + (semanticRemainder ?? "")
        var selected = Set(allergens.filter { wording.contains($0.label) }.map(\.key))
        selected.formUnion(allergens.filter { option in
            expanded.contains(option.canonicalKey ?? "")
        }.map(\.key))
        return selected
    }
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

    var integerValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var stringValues: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
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
            let minimum = value["min_yen"]?.integerValue
            let maximum = value["max_yen"]?.integerValue
            if let minimum, let maximum { return "\(type.label)：\(yen(minimum))〜\(yen(maximum))" }
            if let maximum { return "\(type.label)：\(yen(maximum))まで" }
            if let minimum { return "\(type.label)：\(yen(minimum))以上" }
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

    static func yen(_ amount: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return "¥\(formatter.string(from: NSNumber(value: amount)) ?? String(amount))"
    }

    static func feedLine(_ item: FeedItem) -> String {
        let who = item.displayName ?? "匿名の参加者"
        let prefix = item.kind == .must ? "絶対に必要" : "できれば欲しい"
        return "\(who)｜\(prefix)：\(summary(type: item.normalizedType, value: item.normalizedValue))"
    }
}
