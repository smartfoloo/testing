import SwiftUI

@MainActor
final class RecommendationListViewModel: ObservableObject {
    @Published var scores: [RecommendationScore] = []
    @Published var features: [String: RestaurantFeature] = [:]
    @Published var explanations: [String: String] = [:]
    @Published var explainingPlaceIds: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    static let fallbackExplanation = AppCopy.fallbackExplanation
    private let service: RecommendationService
    init(service: RecommendationService = RecommendationService()) { self.service = service }

    func load(runId: UUID) async {
        isLoading = true
        errorMessage = nil
        do {
            scores = try await service.scores(runId: runId)
            for score in scores {
                if let explanation = score.explanation?.trimmingCharacters(in: .whitespacesAndNewlines), !explanation.isEmpty {
                    explanations[score.restaurantPlaceId] = explanation
                }
            }
            let loaded = try await service.features(placeIds: scores.map(\.restaurantPlaceId))
            features = Dictionary(uniqueKeysWithValues: loaded.map { ($0.placeId, $0) })
        } catch { errorMessage = AppCopy.networkError }
        isLoading = false
    }

    func explain(score: RecommendationScore, runId: UUID) async {
        guard explanations[score.restaurantPlaceId] == nil else { return }
        explainingPlaceIds.insert(score.restaurantPlaceId)
        defer { explainingPlaceIds.remove(score.restaurantPlaceId) }
        do {
            let value = try await service.explanation(runId: runId, restaurantPlaceId: score.restaurantPlaceId)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            explanations[score.restaurantPlaceId] = value.isEmpty ? Self.fallbackExplanation : value
        } catch { explanations[score.restaurantPlaceId] = Self.fallbackExplanation }
    }
}

struct RecommendationListView: View {
    let runId: UUID
    let eventId: UUID
    var onChosen: (EventDecision) -> Void
    @StateObject private var viewModel = RecommendationListViewModel()
    @State private var decision: EventDecision?
    @State private var isChoosing = false
    @State private var choiceError: String?
    private let eventService = EventService()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppSpacing.lg) {
                if viewModel.isLoading && viewModel.scores.isEmpty {
                    LoadingStateView(title: "おすすめのお店を読み込んでいます")
                } else if !viewModel.isLoading && viewModel.scores.isEmpty {
                    EmptyStateView(title: AppCopy.noResults, message: "条件を少し見直すと、候補が増えるかもしれません。")
                }
                ForEach(viewModel.scores) { score in
                    RecommendationCardView(
                        score: score,
                        feature: viewModel.features[score.restaurantPlaceId],
                        explanation: viewModel.explanations[score.restaurantPlaceId],
                        isExplaining: viewModel.explainingPlaceIds.contains(score.restaurantPlaceId),
                        isOrganizer: true,
                        isChosen: decision?.chosenPlaceId == score.restaurantPlaceId,
                        onChoose: { Task { await choose(score: score) } }
                    )
                    .task { await viewModel.explain(score: score, runId: runId) }
                }
                if let choiceMessage = choiceError {
                    InlineErrorView(message: choiceMessage) { self.choiceError = nil }
                }
                if let errorMessage = viewModel.errorMessage {
                    InlineErrorView(message: errorMessage) { Task { await viewModel.load(runId: runId) } }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .navigationTitle(AppCopy.recommendations)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load(runId: runId)
            do {
                decision = try await eventService.decision(eventId: eventId)
            } catch {
                choiceError = AppCopy.networkError
            }
        }
    }

    private func choose(score: RecommendationScore) async {
        guard !isChoosing else { return }
        isChoosing = true
        choiceError = nil
        do {
            let result = try await eventService.chooseRestaurant(eventId: eventId, placeId: score.restaurantPlaceId)
            decision = result
            onChosen(result)
        } catch { choiceError = AppCopy.networkError }
        isChoosing = false
    }
}
