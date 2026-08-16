import Foundation
import Supabase

struct ConstraintService {
    private let client: SupabaseClient

    init(client: SupabaseClient = Supa.client) {
        self.client = client
    }

    private struct ParseRequest: Encodable {
        let mode = "parse"
        let raw_text: String
        let kind: String
        let language: String
    }

    func parse(rawText: String, kind: ConstraintKind, language: String = "en") async throws -> ParseResult {
        try await client.functions.invoke(
            "llm-assist",
            options: FunctionInvokeOptions(
                body: ParseRequest(raw_text: rawText, kind: kind.rawValue, language: language)
            )
        )
    }

    private static let savedConstraintColumns = """
        id, kind, raw_text, normalized_type, normalized_value, visibility, sensitivity, \
        verification_requirement, semantic_remainder, created_at, updated_at
        """

    private struct ConstraintInsert: Encodable {
        let event_id: UUID
        let participant_id: UUID
        let kind: String
        let raw_text: String
        let normalized_type: String
        let normalized_value: [String: JSONValue]
        let visibility: String
        let semantic_remainder: String?
    }

    private struct ConstraintUpdate: Encodable {
        let kind: String
        let raw_text: String
        let normalized_type: String
        let normalized_value: [String: JSONValue]
        let visibility: String
        let semantic_remainder: String?
    }

    struct SavedConstraint: Decodable, Identifiable, Hashable {
        let id: UUID
        let kind: ConstraintKind
        let rawText: String
        let normalizedType: NormalizedType
        let normalizedValue: [String: JSONValue]
        let visibility: ConstraintVisibility
        let sensitivity: ConstraintSensitivity
        let verificationRequirement: VerificationRequirement
        let semanticRemainder: String?
        let createdAt: Date
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case kind
            case rawText = "raw_text"
            case normalizedType = "normalized_type"
            case normalizedValue = "normalized_value"
            case visibility
            case sensitivity
            case verificationRequirement = "verification_requirement"
            case semanticRemainder = "semantic_remainder"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    func insertConstraint(
        eventId: UUID,
        participantId: UUID,
        kind: ConstraintKind,
        rawText: String,
        normalizedType: NormalizedType,
        normalizedValue: [String: JSONValue],
        visibility: ConstraintVisibility,
        semanticRemainder: String? = nil
    ) async throws -> SavedConstraint {
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
            .select(Self.savedConstraintColumns)
            .single()
            .execute()
            .value
    }

    func updateConstraint(
        id: UUID,
        kind: ConstraintKind,
        rawText: String,
        normalizedType: NormalizedType,
        normalizedValue: [String: JSONValue],
        visibility: ConstraintVisibility,
        semanticRemainder: String?
    ) async throws -> SavedConstraint {
        try await client
            .from("participant_constraints")
            .update(ConstraintUpdate(
                kind: kind.rawValue,
                raw_text: rawText,
                normalized_type: normalizedType.rawValue,
                normalized_value: normalizedValue,
                visibility: visibility.rawValue,
                semantic_remainder: semanticRemainder
            ))
            .eq("id", value: id)
            .select(Self.savedConstraintColumns)
            .single()
            .execute()
            .value
    }

    func deleteConstraint(id: UUID) async throws {
        let deleted: [DeletedConstraint] = try await client
            .from("participant_constraints")
            .delete()
            .eq("id", value: id)
            .select("id")
            .execute()
            .value
        guard !deleted.isEmpty else {
            throw NSError(domain: "ConstraintService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "preferences are closed or constraint unavailable"
            ])
        }
    }

    func ownConstraints(participantId: UUID) async throws -> [SavedConstraint] {
        try await client
            .from("participant_constraints")
            .select(Self.savedConstraintColumns)
            .eq("participant_id", value: participantId)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    private struct FeedParams: Encodable {
        let p_event_id: UUID
    }

    func sanitizedFeed(eventId: UUID) async throws -> [FeedItem] {
        try await client
            .rpc("fn_get_sanitized_feed", params: FeedParams(p_event_id: eventId))
            .execute()
            .value
    }

    private struct DeletedConstraint: Decodable {
        let id: UUID
    }

    func constraintBroadcasts(
        eventId: UUID
    ) async throws -> (channel: RealtimeTopicSubscription, stream: AsyncStream<Void>) {
        let (subscription, streams) = try await RealtimeTopicRegistry.shared.subscribe(
            topic: RealtimeTopicRegistry.eventTopic(eventId: eventId),
            events: [.constraintAdded, .constraintUpdated, .constraintDeleted],
            client: client
        )
        guard let additions = streams[.constraintAdded],
              let updates = streams[.constraintUpdated],
              let deletions = streams[.constraintDeleted]
        else {
            await RealtimeTopicRegistry.shared.release(subscription)
            throw NSError(domain: "ConstraintService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "constraint broadcast streams unavailable"
            ])
        }

        let stream = AsyncStream<Void> { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in additions { continuation.yield(()) }
                    }
                    group.addTask {
                        for await _ in updates { continuation.yield(()) }
                    }
                    group.addTask {
                        for await _ in deletions { continuation.yield(()) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (subscription, stream)
    }
}
