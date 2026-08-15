import Supabase
import SwiftUI

struct GroupActivityFeedView: View {
    let eventId: UUID

    private let service = ConstraintService()

    @State private var items: [FeedItem] = []
    @State private var lastPayload: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if items.isEmpty {
                Text("No shared requirements yet.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ConstraintFormatter.feedLine(item))
                    Text(item.displayName == nil ? "Anonymous" : item.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let lastPayload {
                Section("Last broadcast payload") {
                    Text(lastPayload).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Group activity")
        .task { await listen() }
    }

    private func listen() async {
        do {
            items = try await service.sanitizedFeed(eventId: eventId)
            let (channel, stream) = try await service.constraintBroadcasts(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }

            for await (item, payload) in stream {
                lastPayload = Self.describe(payload)
                if !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renders the payload exactly as received, so `display_name: null` on ANONYMOUS entries
    /// can be verified from the wire, not just from what the row renders as.
    private static func describe(_ payload: [String: AnyJSON]) -> String {
        payload
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.isNil ? "null" : String(describing: $0.value.value))" }
            .joined(separator: "\n")
    }
}
