import Foundation
import SwiftUI

@MainActor
final class RecommendationListViewModel: ObservableObject {
    @Published var scores: [RecommendationScore] = []
    @Published var features: [String: RestaurantFeature] = [:]
    @Published var explanations: [String: String] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    static let fallbackExplanation =
        "We couldn't write a summary for this one, but it clears every requirement the group shared."

    private let service: RecommendationService

    init(service: RecommendationService = RecommendationService()) {
        self.service = service
    }

    func load(runId: UUID) async {
        isLoading = true
        do {
            let scores = try await service.scores(runId: runId)
            self.scores = scores
            for score in scores where score.explanation?.isEmpty == false {
                explanations[score.restaurantPlaceId] = score.explanation
            }
            let loaded = try await service.features(
                placeIds: scores.map(\.restaurantPlaceId)
            )
            features = Dictionary(uniqueKeysWithValues: loaded.map { ($0.placeId, $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// A failed or slow explanation must never block the card: the score, label and
    /// features are already rendered, and a neutral fallback fills the text.
    func explain(score: RecommendationScore, runId: UUID) async {
        guard explanations[score.restaurantPlaceId] == nil else { return }
        do {
            explanations[score.restaurantPlaceId] = try await service.explanation(
                runId: runId,
                restaurantPlaceId: score.restaurantPlaceId
            )
        } catch {
            explanations[score.restaurantPlaceId] = Self.fallbackExplanation
        }
    }
}

struct RecommendationListView: View {
    let runId: UUID

    @StateObject private var viewModel = RecommendationListViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if viewModel.isLoading && viewModel.scores.isEmpty {
                    ProgressView().padding(.top, 40)
                }

                ForEach(viewModel.scores) { score in
                    RecommendationCardView(
                        score: score,
                        feature: viewModel.features[score.restaurantPlaceId],
                        explanation: viewModel.explanations[score.restaurantPlaceId]
                    )
                    .task { await viewModel.explain(score: score, runId: runId) }
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Recommendations")
        .task { await viewModel.load(runId: runId) }
    }
}
