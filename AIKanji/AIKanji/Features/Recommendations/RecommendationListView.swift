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

/// PRD §9: the 幹事's objective changes the emphasis, not the feasibility. Saying that once
/// above the list keeps every card free to spend its space on its own numbers, and gives the
/// per-card 「重視」 dots and 「未確認」 marks a single place to be explained.
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

/// Recruit's Hot Pepper Gourmet Web Service guideline requires this credit wherever their data
/// is used, so it lives at the foot of the shortlist — the one screen that prints the fields we
/// merge from them (the yen band and the 個室 line on every card). It is not a feature: muted
/// secondary caption, below the content, never above 「このお店に決める」.
///
/// One credit for the whole list, not one per card. The chosen card is the same
/// `RecommendationCardView` with 「このお店に決まりました」 swapped in for the button, and it stays
/// inside this list, so it is already covered — repeating the credit three or four times would
/// be louder than the guideline asks and would compete with the decision itself. (The
/// 「決まりました」 banner on EventHomeView and the organizer dashboard show only a name the group
/// chose, which is the group's own decision rather than a Hot Pepper listing.)
///
/// Two credits, because two providers impose obligations and neither discharges the other's.
/// Each keeps its own scope sentence so neither over-claims: Hot Pepper supplies 個室 and the
/// yen band, Places supplies the discovery itself plus the name, location and rating/review
/// count. Google's Places policy requires Google Maps attribution wherever Places content is
/// displayed without a Google map, which is exactly this screen.
///
/// Mirrors `ProviderAttribution` in web/src/features/Recommendations.tsx.
private struct ProviderAttribution: View {
    /// The per-place third-party attributions Places returns, already reduced to display-ready
    /// lines by whatever owns the type. The policy says they must be displayed with the content
    /// they belong to, so they render inside the same block as the credit.
    ///
    /// TODO(B5): nothing can pass these yet, so they are never shown. The storage half exists —
    /// `restaurant_features.provider_attributions` (jsonb, migration 0023), written by
    /// `fn_record_provider_attributions` from the `places.attributions` the search now requests
    /// — but no client type carries it: `RestaurantFeature` in Models/Recommendation.swift has
    /// no such field and `RecommendationService.features(placeIds:)` does not select it. Wiring
    /// it up means (a) adding the field where the type lives, and (b) deciding how an element
    /// that arrives as an object (Places (New) documents a provider name plus a provider URI)
    /// becomes one line, since elements are stored verbatim as either a string or an object and
    /// rewriting a credit is a misattribution. No field name or element shape is invented here.
    var placeAttributions: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(AttributionCopy.scope)
                    .font(AppTypography.small)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                // An explicit Text label, because Link would otherwise tint its title with the
                // accent colour and this is a footnote, not a call to action. The underline is
                // what carries the "this is tappable" affordance instead.
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
                // The text form of the attribution, not a bundled logo asset: Google's brand
                // rules govern the image, and a wrong or stale logo would be a worse violation
                // than the text form their policy sanctions where space is limited. Unmodified
                // and at full ink contrast rather than the 0.72 used for our own footnotes,
                // because the policy requires it to stay legible — and not a Link, since the
                // policy asks for the attribution itself, and inventing a destination for
                // Google's mark would imply more than it says.
                Text(AttributionCopy.googleCredit)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("google-attribution-credit")
                if !placeAttributions.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        // Rendered as text, verbatim. These strings are HTML-ish, and handing
                        // third-party markup to AttributedString(markdown:) or a web view is
                        // not an option here, so the characters are preserved exactly as given
                        // rather than interpreted. `Text(String)` does no markdown parsing —
                        // only literals are parsed — which is what keeps them intact.
                        ForEach(placeAttributions, id: \.self) { attribution in
                            Text(attribution)
                                .font(AppTypography.small)
                                .foregroundStyle(AppColors.ink.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("place-attributions")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                // Every row of a run shares the objective, so the first stored breakdown
                // speaks for the whole list.
                if let legendBreakdown = viewModel.scores.compactMap(\.scoreBreakdown).first {
                    ObjectiveLegend(breakdown: legendBreakdown)
                }
                ForEach(viewModel.scores) { score in
                    RecommendationCardView(
                        score: score,
                        feature: viewModel.features[score.restaurantPlaceId],
                        explanation: viewModel.explanations[score.restaurantPlaceId],
                        isExplaining: viewModel.explainingPlaceIds.contains(score.restaurantPlaceId),
                        isOrganizer: isOrganizer,
                        isChosen: decision?.chosenPlaceId == score.restaurantPlaceId,
                        isChoosing: isChoosing,
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
                // Nothing sourced is on screen when the list is empty, so there is nothing
                // to credit yet.
                if !viewModel.scores.isEmpty {
                    ProviderAttribution()
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
        } catch { choiceError = AppCopy.errorMessage(for: error) }
        isChoosing = false
    }
}
