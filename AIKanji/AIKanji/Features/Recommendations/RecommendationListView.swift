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

    init(service: RecommendationService = RecommendationService()) {
        self.service = service
    }

    func load(runId: UUID) async {
        isLoading = true
        errorMessage = nil
        scores = []
        features = [:]
        explanations = [:]
        do {
            scores = try await service.scores(runId: runId)
            for score in scores {
                if let explanation = score.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !explanation.isEmpty {
                    explanations[score.restaurantPlaceId] = explanation
                }
            }
            let loaded = try await service.features(placeIds: scores.map(\.restaurantPlaceId))
            features = Dictionary(uniqueKeysWithValues: loaded.map { ($0.placeId, $0) })
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
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
        } catch {
            explanations[score.restaurantPlaceId] = Self.fallbackExplanation
        }
    }
}

private struct ObjectiveLegend: View {
    let breakdown: ScoreBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(AppCopy.objectiveEmphasis(breakdown))
                .font(AppTypography.caption.weight(.semibold))
                .accessibilityIdentifier("score-emphasis")
            Text(ScoreCopy.legendNote)
                .font(AppTypography.small)
                .foregroundStyle(AppColors.ink.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(AppColors.greenSoft)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .accessibilityIdentifier("score-legend")
    }
}

private struct ProviderAttribution: View {
    let placeAttributions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(AttributionCopy.scope)
                    .font(AppTypography.small)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: AttributionCopy.url) {
                    Text(AttributionCopy.credit)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                        .underline()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("provider-attribution-link")
            }
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(AttributionCopy.googleScope)
                    .font(AppTypography.small)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                Text(AttributionCopy.googleCredit)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("google-attribution-credit")
                if !placeAttributions.isEmpty {
                    ForEach(placeAttributions, id: \.self) { attribution in
                        Text(attribution)
                            .font(AppTypography.small)
                            .foregroundStyle(AppColors.ink.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("place-attributions")
                }
            }
            .accessibilityIdentifier("google-attribution")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("provider-attribution")
    }
}

struct RecommendationListView: View {
    let runId: UUID
    let eventId: UUID
    let isOrganizer: Bool
    @Binding var decision: EventDecision?
    var onChosen: (EventDecision) -> Void
    @StateObject private var viewModel = RecommendationListViewModel()
    @State private var pendingChoice: RecommendationScore?
    @State private var isChoosing = false
    @State private var choiceError: String?
    private let eventService = EventService()

    private var providerAttributions: [String] {
        Array(Set(viewModel.features.values.flatMap(\.providerAttributionLines))).sorted()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppSpacing.lg) {
                if !isOrganizer {
                    Text("候補を確認できます。お店の決定は幹事が行います。")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if viewModel.isLoading && viewModel.scores.isEmpty {
                    LoadingStateView(title: "おすすめのお店を読み込んでいます")
                } else if !viewModel.isLoading && viewModel.scores.isEmpty {
                    EmptyStateView(title: AppCopy.noResults, message: "条件を少し見直すと、候補が増えるかもしれません。")
                }
                if let breakdown = viewModel.scores.compactMap(\.scoreBreakdown).first {
                    ObjectiveLegend(breakdown: breakdown)
                }
                ForEach(viewModel.scores) { score in
                    RecommendationCardView(
                        score: score,
                        feature: viewModel.features[score.restaurantPlaceId],
                        explanation: viewModel.explanations[score.restaurantPlaceId],
                        isExplaining: viewModel.explainingPlaceIds.contains(score.restaurantPlaceId),
                        isOrganizer: isOrganizer,
                        isChosen: decision?.chosenPlaceId == score.restaurantPlaceId,
                        hasDecision: decision?.chosenPlaceId != nil,
                        isChoosing: isChoosing,
                        onChoose: { pendingChoice = score }
                    )
                    .task { await viewModel.explain(score: score, runId: runId) }
                }
                if let choiceError {
                    InlineErrorView(message: choiceError) { self.choiceError = nil }
                }
                if let errorMessage = viewModel.errorMessage {
                    InlineErrorView(message: errorMessage) { Task { await viewModel.load(runId: runId) } }
                }
                if !viewModel.scores.isEmpty {
                    ProviderAttribution(placeAttributions: providerAttributions)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .task(id: runId) { await viewModel.load(runId: runId) }
        .confirmationDialog(
            decision?.chosenPlaceId == nil ? "このお店に決めますか？" : "決定したお店を変更しますか？",
            isPresented: Binding(
                get: { pendingChoice != nil },
                set: { if !$0 { pendingChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingChoice {
                Button(decision?.chosenPlaceId == nil ? "このお店に決める" : "このお店に変更する") {
                    let choice = pendingChoice
                    self.pendingChoice = nil
                    Task { await choose(score: choice) }
                }
                Button(AppCopy.cancel, role: .cancel) { self.pendingChoice = nil }
            }
        } message: {
            if let pendingChoice {
                Text(viewModel.features[pendingChoice.restaurantPlaceId]?.name ?? "おすすめのお店")
            }
        }
    }

    private func choose(score: RecommendationScore) async {
        guard !isChoosing else { return }
        isChoosing = true
        choiceError = nil
        defer { isChoosing = false }
        do {
            let result = try await eventService.chooseRestaurant(eventId: eventId, placeId: score.restaurantPlaceId)
            onChosen(result)
        } catch {
            choiceError = AppCopy.errorMessage(for: error)
        }
    }
}
