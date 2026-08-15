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
    }

    /// Direct table insert — RLS allows a participant to write only their own rows.
    func insertConstraint(
        eventId: UUID,
        participantId: UUID,
        kind: ConstraintKind,
        rawText: String,
        normalizedType: NormalizedType,
        normalizedValue: [String: JSONValue],
        visibility: ConstraintVisibility
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
                visibility: visibility.rawValue
            ))
            .execute()
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
    func constraintBroadcasts(eventId: UUID) async throws -> (channel: RealtimeChannelV2, stream: AsyncStream<(item: FeedItem, payload: [String: AnyJSON])>) {
        let channel = client.channel("event-\(eventId.uuidString.lowercased())") { config in
            config.isPrivate = true
        }
        let broadcasts = channel.broadcastStream(event: "constraint_added")
        try await channel.subscribeWithError()

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

        return (channel, stream)
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
