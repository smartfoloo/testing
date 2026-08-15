import Foundation
import Supabase

struct ConstraintService {
    private let client: SupabaseClient

    init(client: SupabaseClient = Supa.client) {
        self.client = client
    }

    // MARK: - Parse

    private struct ParseRequest: Encodable {
        let mode = "parse"
        let raw_text: String
        let kind: String
        let language: String
    }

    /// Calls the `llm-assist` Edge Function. The function itself never fails on a bad model
    /// response — it answers with a `needs_clarification` fallback instead.
    func parse(rawText: String, kind: ConstraintKind, language: String = "en") async throws -> ParseResult {
        try await client.functions.invoke(
            "llm-assist",
            options: FunctionInvokeOptions(
                body: ParseRequest(raw_text: rawText, kind: kind.rawValue, language: language)
            )
        )
    }

    // MARK: - Insert

    private struct ConstraintInsert: Encodable {
        let event_id: UUID
        let participant_id: UUID
        let kind: String
        let raw_text: String
        let normalized_type: String
        let normalized_value: [String: JSONValue]
        let visibility: String
        /// What the taxonomy could not express, kept for P1 semantic matching. `sensitivity`
        /// and `verification_requirement` are deliberately absent: 0018's BEFORE-INSERT
        /// trigger decides both server-side, and sensitivity must never touch `visibility`,
        /// which stays the participant's own choice.
        let semantic_remainder: String?
    }

    /// Direct table insert — RLS allows a participant to write only their own rows, and
    /// after `fn_close_preferences` the `with check` clause rejects the write outright, so a
    /// post-close save fails loudly instead of silently updating nothing.
    func insertConstraint(
        eventId: UUID,
        participantId: UUID,
        kind: ConstraintKind,
        rawText: String,
        normalizedType: NormalizedType,
        normalizedValue: [String: JSONValue],
        visibility: ConstraintVisibility,
        semanticRemainder: String? = nil
    ) async throws {
        try await client
            .from("participant_constraints")
            .insert(ConstraintInsert(
                event_id: eventId,
                participant_id: participantId,
                kind: kind.rawValue,
                raw_text: rawText,
                normalized_type: normalizedType.rawValue,
                normalized_value: normalizedValue,
                visibility: visibility.rawValue,
                semantic_remainder: semanticRemainder
            ))
            .execute()
    }

    struct SavedConstraint: Decodable, Identifiable {
        let id: UUID
        let kind: ConstraintKind
        let rawText: String

        enum CodingKeys: String, CodingKey {
            case id
            case kind
            case rawText = "raw_text"
        }
    }

    func ownConstraints(participantId: UUID) async throws -> [SavedConstraint] {
        try await client
            .from("participant_constraints")
            .select("id, kind, raw_text")
            .eq("participant_id", value: participantId)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    // MARK: - Feed

    private struct FeedParams: Encodable {
        let p_event_id: UUID
    }

    func sanitizedFeed(eventId: UUID) async throws -> [FeedItem] {
        try await client
            .rpc("fn_get_sanitized_feed", params: FeedParams(p_event_id: eventId))
            .execute()
            .value
    }

    /// Subscribes to the private `event-{id}` topic and yields sanitized broadcast payloads.
    /// The raw payload is exposed too so callers can assert on what the server actually sent.
    /// The feed is a broadcast rather than a table read because RLS hides other participants'
    /// constraint rows: the server sanitizes, then sends.
    ///
    /// The channel comes from `RealtimeTopicRegistry` because the organizer dashboard listens
    /// for `run_updated` on this same topic, and Realtime keys channels by topic — a second
    /// channel here would fight the dashboard's instead of multiplexing with it. What is
    /// handed back is this listener's hold on the shared channel, which
    /// `Supa.client.removeChannel(_:)` releases; the channel goes only with the last release.
    func constraintBroadcasts(eventId: UUID) async throws -> (channel: RealtimeTopicSubscription, stream: AsyncStream<(item: FeedItem, payload: [String: AnyJSON])>) {
        let (subscription, broadcasts) = try await RealtimeTopicRegistry.shared.subscribe(
            topic: RealtimeTopicRegistry.eventTopic(eventId: eventId),
            event: .constraintAdded,
            client: client
        )

        let stream = AsyncStream<(item: FeedItem, payload: [String: AnyJSON])> { continuation in
            let task = Task {
                for await message in broadcasts {
                    guard let payload = message["payload"]?.objectValue,
                          let item = try? Self.decodeFeedItem(from: payload)
                    else { continue }
                    continuation.yield((item, payload))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return (subscription, stream)
    }

    static func decodeFeedItem(from payload: [String: AnyJSON]) throws -> FeedItem {
        let data = try JSONEncoder().encode(payload)
        return try feedDecoder.decode(FeedItem.self, from: data)
    }

    private static let feedDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unrecognized timestamp: \(text)"
            )
        }
        return decoder
    }()

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
