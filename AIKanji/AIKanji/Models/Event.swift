import Foundation

enum EventObjective: String, Codable, CaseIterable, Identifiable {
    case balanced, access, cost, experience, custom
    var id: String { rawValue }
    var label: String { AppCopy.objective(self) }
}

enum EventStatus: String, Codable {
    case collecting, negotiating, ready, closed
}

struct OriginSelection: Codable, Hashable {
    let label: String
    let latitude: Double
    let longitude: Double

    static var uiTestDefault: OriginSelection? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AIKanjiUITestOrigin") {
            return OriginSelection(label: "渋谷駅、東京都渋谷区", latitude: 35.6580, longitude: 139.7016)
        }
#endif
        return nil
    }
}

struct Event: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let inviteCode: String
    let organizerParticipantId: UUID?
    let objective: EventObjective
    let status: EventStatus
    let scheduledAt: Date?
    let chosenPlaceId: String?
    let chosenAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case inviteCode = "invite_code"
        case organizerParticipantId = "organizer_participant_id"
        case objective
        case status
        case scheduledAt = "scheduled_at"
        case chosenPlaceId = "chosen_place_id"
        case chosenAt = "chosen_at"
        case createdAt = "created_at"
    }
}

struct CreatedEvent: Codable, Hashable {
    let eventId: UUID
    let inviteCode: String
    let participantId: UUID

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case inviteCode = "invite_code"
        case participantId = "participant_id"
    }
}

struct EventPreview: Codable, Hashable {
    let eventId: UUID
    let name: String
    let status: EventStatus
    let scheduledAt: Date?
    let participantCount: Int
    let organizerDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case name
        case status
        case scheduledAt = "scheduled_at"
        case participantCount = "participant_count"
        case organizerDisplayName = "organizer_display_name"
    }
}

struct MemberEvent: Codable, Identifiable, Hashable {
    let eventId: UUID
    let name: String
    let inviteCode: String
    let status: EventStatus
    let scheduledAt: Date?
    let participantId: UUID
    let role: ParticipantRole
    let participantCount: Int
    let completedCount: Int
    let inputCompleted: Bool
    let latestRunId: UUID?
    let latestRunAt: Date?
    let feasibleCount: Int?
    let chosenPlaceId: String?
    let chosenAt: Date?

    var id: UUID { eventId }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case name
        case inviteCode = "invite_code"
        case status
        case scheduledAt = "scheduled_at"
        case participantId = "participant_id"
        case role
        case participantCount = "participant_count"
        case completedCount = "completed_count"
        case inputCompleted = "input_completed"
        case latestRunId = "latest_run_id"
        case latestRunAt = "latest_run_at"
        case feasibleCount = "feasible_count"
        case chosenPlaceId = "chosen_place_id"
        case chosenAt = "chosen_at"
    }
}

struct EventProgress: Codable, Hashable {
    let participantCount: Int
    let completedCount: Int
    let inputCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case participantCount = "participant_count"
        case completedCount = "completed_count"
        case inputCompleted = "input_completed"
    }
}

struct EventProgressUpdate: Codable, Hashable {
    let participantCount: Int
    let completedCount: Int

    enum CodingKeys: String, CodingKey {
        case participantCount = "participant_count"
        case completedCount = "completed_count"
    }
}

struct EventDecision: Codable, Hashable {
    let chosenPlaceId: String?
    let chosenAt: Date?

    enum CodingKeys: String, CodingKey {
        case chosenPlaceId = "chosen_place_id"
        case chosenAt = "chosen_at"
    }
}

enum EventDecisionOrdering {
    static func isNewer(
        _ candidate: EventDecision,
        than current: EventDecision?,
        authoritativeLegacy: Bool = false
    ) -> Bool {
        guard let current else { return true }
        switch (candidate.chosenAt, current.chosenAt) {
        case let (candidateAt?, currentAt?):
            if candidateAt != currentAt { return candidateAt > currentAt }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            if authoritativeLegacy { return candidate != current }
        }
        return (candidate.chosenPlaceId ?? "") > (current.chosenPlaceId ?? "")
    }
}

struct CollectionReadiness: Codable, Hashable {
    let participantCount: Int
    let respondedCount: Int
    let thresholdCount: Int
    let thresholdMet: Bool
    let provisionalReady: Bool
    let preferencesClosed: Bool
    let preferencesClosedAt: String?

    enum CodingKeys: String, CodingKey {
        case participantCount = "participant_count"
        case respondedCount = "responded_count"
        case thresholdCount = "threshold_count"
        case thresholdMet = "threshold_met"
        case provisionalReady = "provisional_ready"
        case preferencesClosed = "preferences_closed"
        case preferencesClosedAt = "preferences_closed_at"
    }

    var isComplete: Bool {
        participantCount > 0 && respondedCount >= participantCount
    }

    var closedAt: Date? { Self.timestamp(preferencesClosedAt) }

    static func timestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum InviteLink {
    static let base: URL? = {
        guard let raw = (Bundle.main.object(forInfoDictionaryKey: "INVITE_LINK_BASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)")
    }()

    static func url(code: String, base: URL? = InviteLink.base) -> URL? {
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url
    }

    static func shareText(code: String) -> String {
        url(code: code)?.absoluteString ?? code
    }
}
