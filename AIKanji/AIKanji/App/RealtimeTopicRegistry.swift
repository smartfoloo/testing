import Foundation
import Supabase

/// One listener's hold on a shared topic channel.
///
/// Handed back where the services used to hand back the `RealtimeChannelV2` itself. That
/// mattered: a caller that owns the channel can remove it, and with the channel now shared
/// between the group feed and the organizer dashboard, removing it would deafen the other
/// screen. A hold can only be released, and only the last release removes the channel — see
/// `SupabaseClient.removeChannel(_:)` below, which keeps the existing
/// `defer { Task { await Supa.client.removeChannel(channel) } }` teardown compiling and
/// correct.
struct RealtimeTopicSubscription: Sendable, Hashable {
    let topic: String
    fileprivate let id: UUID
}

/// One Realtime channel per topic, shared by every service listening on that topic.
///
/// Supabase Realtime keys channels by topic, so two channels on `event-{id}` are not a way
/// to multiplex two broadcast events: the second join can error, or the two objects fight
/// over one underlying subscription. The group feed (`constraint_added`, 0004) and the
/// organizer dashboard (`run_updated`, 0006/0009) are exactly that pair, and 0015's
/// `event_decided` and 0018's `preferences_closed` arrive on the same topic — so the channel
/// is reference-counted here instead of owned by whichever screen opened first. Adding a
/// listener for a new event is a `subscribe(topic:event:client:)` call and nothing else.
///
/// Broadcast is what makes multiplexing safe. Unlike `postgres_changes`, whose filters
/// travel inside the join payload, broadcast messages are dispatched to per-event callbacks
/// on the client, so a second listener may attach after the join has already happened.
///
/// An `actor` because both call sites are `async` and can be entered from different tasks:
/// fixing a channel race by introducing a data race would be no fix at all. Every field
/// below is touched only from inside this actor.
actor RealtimeTopicRegistry {
    static let shared = RealtimeTopicRegistry()

    /// Every broadcast event the SQL side sends on `event-{id}`. `realtime.send` names the
    /// event, and the client dispatches by that name, so this list is the contract with the
    /// migrations — not something a caller should be free to spell.
    enum EventBroadcast: String, Sendable {
        /// 0004's `trg_broadcast_constraint`, sanitized: PRIVATE rows never reach it.
        case constraintAdded = "constraint_added"
        /// 0006/0009's recommendation-run triggers.
        case runUpdated = "run_updated"
        /// `fn_choose_restaurant` (0015).
        case eventDecided = "event_decided"
        /// `fn_close_preferences` (0018).
        case preferencesClosed = "preferences_closed"
    }

    /// Must stay `event-<lowercased uuid>`: the triggers broadcast to
    /// `'event-' || event_id::text` and Postgres renders a uuid in lower case, and 0004's
    /// policy on `realtime.messages` authorizes the join by comparing that exact string to
    /// `realtime.topic()`. A different spelling is not a cosmetic difference — it is a topic
    /// nobody is allowed to join and nobody broadcasts to.
    static func eventTopic(eventId: UUID) -> String {
        "event-\(eventId.uuidString.lowercased())"
    }

    private struct Entry {
        /// Identifies this channel, so a failed or finished generation can never discard a
        /// channel that a later subscriber has since joined.
        let generation: UUID
        let client: SupabaseClient
        let channel: RealtimeChannelV2
        /// The one join, awaited by every subscriber: the second listener must not send a
        /// second join, but it must still see the first one's failure.
        let join: Task<Void, Error>
        var subscribers: Set<UUID>
    }

    private struct Removal {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private var entries: [String: Entry] = [:]
    private var removals: [String: Removal] = [:]

    /// Attaches `event` to the topic's channel, joining it first if nobody has yet.
    ///
    /// `subscribeWithError()`'s failure is propagated unchanged: a screen that cannot join
    /// has to be able to say so rather than sit silently receiving nothing.
    func subscribe(
        topic: String,
        event: EventBroadcast,
        client: SupabaseClient
    ) async throws -> (subscription: RealtimeTopicSubscription, messages: AsyncStream<[String: AnyJSON]>) {
        // A removal must complete before the next join for the same topic. Otherwise a rapid
        // screen change joins a channel the socket is still tearing down, and the new screen
        // ends up subscribed to nothing. The loop re-checks because the wait is a suspension
        // point: another teardown may have started while we were parked here.
        while let removal = removals[topic] {
            await removal.task.value
        }

        // Nothing below suspends until the join is awaited, so this stretch is atomic with
        // respect to actor reentrancy: two first subscribers cannot both create a channel.
        let id = UUID()
        let entry: Entry
        if var existing = entries[topic] {
            existing.subscribers.insert(id)
            entries[topic] = existing
            entry = existing
        } else {
            entry = makeEntry(topic: topic, client: client, firstSubscriber: id)
            entries[topic] = entry
        }
        // Attached before the join is awaited, so a message broadcast while joining is not
        // lost. For a later subscriber the channel is already joined, which is fine: the
        // callback is local.
        let messages = entry.channel.broadcastStream(event: event.rawValue)

        // Rethrown as-is. By the time the join reports failure it has already discarded its
        // entry, so no half-dead channel is left behind for the next subscriber to inherit
        // and this subscriber's hold went with it.
        try await entry.join.value

        return (RealtimeTopicSubscription(topic: topic, id: id), messages)
    }

    /// Drops one hold. The channel survives while anyone else is listening — the organizer
    /// dashboard closing must not silence the group feed.
    func release(_ subscription: RealtimeTopicSubscription) async {
        guard var entry = entries[subscription.topic],
              entry.subscribers.remove(subscription.id) != nil
        else {
            // Unknown hold: already released, or its generation was discarded by a failed
            // join. Either way there is nothing to remove.
            return
        }

        guard entry.subscribers.isEmpty else {
            entries[subscription.topic] = entry
            return
        }
        entries[subscription.topic] = nil
        await remove(entry, topic: subscription.topic)
    }

    private func makeEntry(topic: String, client: SupabaseClient, firstSubscriber: UUID) -> Entry {
        let generation = UUID()
        // `isPrivate` is the whole security boundary: it makes Realtime run its
        // authorization check, so 0004's policy on `realtime.messages` — not the client —
        // decides who may join this event's topic.
        let channel = client.channel(topic) { config in
            config.isPrivate = true
        }
        let join = Task<Void, Error> {
            do {
                try await channel.subscribeWithError()
            } catch {
                // Cleaned up *before* the failure is visible to anyone awaiting this task,
                // so a failed subscribe cannot poison the topic for later attempts.
                await self.discard(topic: topic, generation: generation)
                throw error
            }
        }
        return Entry(
            generation: generation,
            client: client,
            channel: channel,
            join: join,
            subscribers: [firstSubscriber]
        )
    }

    private func discard(topic: String, generation: UUID) async {
        guard let entry = entries[topic], entry.generation == generation else { return }
        entries[topic] = nil
        await remove(entry, topic: topic)
    }

    /// Publishes the in-flight removal before awaiting it, so a `subscribe` arriving
    /// mid-teardown parks on it instead of racing it.
    private func remove(_ entry: Entry, topic: String) async {
        let generation = UUID()
        // The task body inherits this actor's isolation, so the bookkeeping after the removal
        // needs no hop — and cannot interleave with a `subscribe` mid-update.
        let task = Task<Void, Never> {
            await entry.client.removeChannel(entry.channel)
            self.finishRemoval(topic: topic, generation: generation)
        }
        removals[topic] = Removal(generation: generation, task: task)
        await task.value
    }

    /// Cleared from inside the removal task, so by the time a waiter's `await task.value`
    /// returns the topic is already free and the wait above cannot spin on a finished
    /// removal.
    private func finishRemoval(topic: String, generation: UUID) {
        guard removals[topic]?.generation == generation else { return }
        removals[topic] = nil
    }
}

extension SupabaseClient {
    /// Releases a listener's hold on a shared topic channel.
    ///
    /// The screens tear a listener down with `Supa.client.removeChannel(channel)` in a
    /// `defer`, which with a shared channel has to mean "I have stopped listening", not
    /// "remove the channel" — the other screen may still be on it. This overload keeps that
    /// call site working unchanged; the SDK's own `removeChannel(_: RealtimeChannelV2)` is
    /// untouched and still means what it says.
    func removeChannel(_ subscription: RealtimeTopicSubscription) async {
        await RealtimeTopicRegistry.shared.release(subscription)
    }
}
