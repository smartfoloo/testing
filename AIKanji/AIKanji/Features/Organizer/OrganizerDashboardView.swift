import Foundation
import Supabase
import SwiftUI

/// Organizer-visible state. Every property here is an aggregate: there is deliberately no
/// negotiation id, participant id or constraint id, so the organizer's device never receives
/// who is being asked to relax what — only that something is in flight.
@MainActor
final class OrganizerDashboardViewModel: ObservableObject {
    @Published var responseCount = 0
    @Published var feasibleCount: Int?
    @Published var openNegotiations = 0
    @Published var latestRunId: UUID?
    @Published var isWorking = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let service: NegotiationService

    init(service: NegotiationService = NegotiationService()) {
        self.service = service
    }

    var negotiationInProgress: Bool { openNegotiations > 0 }

    func load(eventId: UUID) async {
        do {
            responseCount = try await service.responseCount(eventId: eventId)
            openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
            if let run = try await service.latestRun(eventId: eventId) {
                feasibleCount = run.feasibleCount
                latestRunId = run.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Live updates come from the `run_updated` broadcast, not a polling timer: a recompute
    /// triggered by someone else's accept lands here without any refresh.
    func listenForRuns(eventId: UUID) async {
        do {
            let (channel, stream) = try await service.runUpdates(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }

            for await update in stream {
                feasibleCount = update.feasibleCount
                latestRunId = update.runId
                openNegotiations = (try? await service.pendingNegotiationCount(eventId: eventId)) ?? 0
                responseCount = (try? await service.responseCount(eventId: eventId)) ?? responseCount
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func findRestaurants(eventId: UUID) async {
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        do {
            let candidates = try await service.findRestaurants(eventId: eventId)
            let result = try await service.recomputeFeasibility(eventId: eventId)
            feasibleCount = result.feasibleCount
            latestRunId = result.runId

            if result.feasibleCount == 0 {
                statusMessage = try await service.proposeRelaxation(eventId: eventId) == nil
                    ? "No requirement can be eased automatically — the group needs to talk this one through."
                    : "Nothing fits everyone yet. We asked one person about a small change."
                openNegotiations = (try? await service.pendingNegotiationCount(eventId: eventId)) ?? 0
            } else if candidates == 0 {
                statusMessage = "Using previously fetched candidates."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

struct OrganizerDashboardView: View {
    let eventId: UUID

    @StateObject private var viewModel = OrganizerDashboardViewModel()
    @State private var openRunId: UUID?

    private var canShowRecommendations: Bool {
        (viewModel.feasibleCount ?? 0) > 0 && viewModel.latestRunId != nil
    }

    var body: some View {
        List {
            Section("Responses") {
                LabeledContent("Requirements submitted", value: "\(viewModel.responseCount)")
            }

            Section("Feasible restaurants") {
                LabeledContent(
                    "Matching every requirement",
                    value: viewModel.feasibleCount.map(String.init) ?? "—"
                )
                if viewModel.negotiationInProgress {
                    Label("Negotiation in progress…", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(viewModel.isWorking ? "Searching…" : "Find restaurants") {
                    Task { await viewModel.findRestaurants(eventId: eventId) }
                }
                .disabled(viewModel.isWorking)

                if canShowRecommendations, let runId = viewModel.latestRunId {
                    Button("See recommendations") { openRunId = runId }
                }
            } footer: {
                Text("We never show you who asked for what — only how many requirements are in.")
            }

            if let statusMessage = viewModel.statusMessage {
                Section { Text(statusMessage).foregroundStyle(.secondary) }
            }
            if let errorMessage = viewModel.errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Organizer")
        .navigationDestination(item: $openRunId) { runId in
            RecommendationListView(runId: runId)
        }
        .task { await viewModel.load(eventId: eventId) }
        .task { await viewModel.listenForRuns(eventId: eventId) }
    }
}
