import Foundation

enum EventObjective: String, Codable, CaseIterable, Identifiable {
    case balanced, access, cost, experience, custom
    var id: String { rawValue }
    var label: String { AppCopy.objective(self) }
}

enum EventStatus: String, Codable {
    case collecting, negotiating, ready, closed
}

struct Event: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let inviteCode: String
    let organizerParticipantId: UUID?
    let objective: EventObjective
    let status: EventStatus
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case inviteCode = "invite_code"
        case organizerParticipantId = "organizer_participant_id"
        case objective
        case status
        case createdAt = "created_at"
    }
}

/// Payload returned by the `fn_create_event` RPC.
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

struct EventDecision: Codable, Hashable {
    let chosenPlaceId: String?
    let chosenAt: Date?

    enum CodingKeys: String, CodingKey {
        case chosenPlaceId = "chosen_place_id"
        case chosenAt = "chosen_at"
    }
}

/// Payload of `fn_get_collection_readiness` (PRD §12 progressive search). Counts *people*,
/// not constraint rows, and carries the threshold the shortlist stops being a coin flip at
/// (`least(n, greatest(3, ceil(0.6n)))`).
struct CollectionReadiness: Codable, Hashable {
    let participantCount: Int
    let respondedCount: Int
    let thresholdCount: Int
    let thresholdMet: Bool
    let provisionalReady: Bool
    let preferencesClosed: Bool
    /// Kept as the raw wire timestamp rather than a `Date`: it arrives inside a jsonb
    /// payload, so it bypasses the SDK's own date strategy. `closedAt` parses it leniently
    /// and answers nil when it cannot, exactly as the web client's `Date.parse` guard does.
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

    /// Everyone who could answer has answered — no further input is expected.
    var isComplete: Bool {
        participantCount > 0 && respondedCount >= participantCount
    }

    var closedAt: Date? { Self.timestamp(preferencesClosedAt) }

    /// jsonb renders `timestamptz` with fractional seconds and an offset; a plain
    /// `ISO8601DateFormatter` rejects the fractional form, so both are tried.
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

/// Invite links (PRD §3: invite "by link/QR", not just a code).
///
/// The base URL is configuration, never a literal in the source: `INVITE_LINK_BASE_URL`
/// comes from `Config.xcconfig` (override it in the gitignored `Secrets.xcconfig`) through
/// `Info.plist`, the same route `SUPABASE_URL` / `SUPABASE_ANON_KEY` take in
/// `App/SupabaseClient.swift`. It ships **empty**, because the alternative is baking a
/// domain nobody owns into every QR code: with no base URL configured the invite falls back
/// to the bare 6-character code, which is exactly today's behaviour.
enum InviteLink {
    /// Nil when unconfigured. Unlike `SupabaseConfig` this never traps: a missing invite
    /// domain degrades to a code, while a missing Supabase URL is not a runnable app.
    static let base: URL? = {
        guard let raw = (Bundle.main.object(forInfoDictionaryKey: "INVITE_LINK_BASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        // Written without a scheme in xcconfig, where `//` starts a comment.
        return URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)")
    }()

    /// `https://<base>/?code=xxxxxx` — the code travels as `?code=`, which
    /// `JoinEventView.extractInviteCode(from:)` already understands, so a scanned QR and a
    /// tapped link resolve identically.
    static func url(code: String, base: URL? = InviteLink.base) -> URL? {
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url
    }

    /// What to put in a QR code or a share sheet: the link when there is one, the bare code
    /// otherwise. Both are accepted by the join screen.
    static func shareText(code: String) -> String {
        url(code: code)?.absoluteString ?? code
    }
}
