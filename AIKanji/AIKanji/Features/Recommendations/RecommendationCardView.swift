import SwiftUI

struct RecommendationCardView: View {
    let score: RecommendationScore
    let feature: RestaurantFeature?
    let explanation: String?
    let isExplaining: Bool
    let isOrganizer: Bool
    let isChosen: Bool
    let onChoose: () -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        .fill(AppColors.accentSoft)
                        .frame(height: 150)
                    Image(systemName: "fork.knife")
                        .font(.system(size: 42))
                        .foregroundStyle(AppColors.accent)
                }
                HStack(alignment: .top) {
                    Text(title).font(AppTypography.title)
                    Spacer()
                    Text(score.label?.badge ?? "おすすめ")
                        .font(AppTypography.small.weight(.bold))
                        .foregroundStyle(AppColors.ink)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, AppSpacing.xs)
                        .background(AppColors.yellow)
                        .clipShape(Capsule())
                }
                if !details.isEmpty {
                    Text(details.joined(separator: "・"))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                }
                if let explanation {
                    Text(explanation).font(AppTypography.body)
                } else if isExplaining {
                    HStack(spacing: AppSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text(AppCopy.writingSummary).font(AppTypography.caption)
                    }
                } else {
                    Text(AppCopy.fallbackExplanation).font(AppTypography.body)
                }
                Text(AppCopy.recommendation(score.label))
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppColors.accent)
                if isOrganizer && !isChosen {
                    PrimaryButton(title: "このお店に決める", systemImage: "checkmark") { onChoose() }
                        .accessibilityIdentifier("choose-restaurant")
                } else if isChosen {
                    Text(AppCopy.chosen)
                        .font(AppTypography.body.weight(.bold))
                        .foregroundStyle(AppColors.accent)
                }
            }
        }
    }

    private var title: String {
        guard let name = feature?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "おすすめのお店"
        }
        return name
    }

    private var details: [String] {
        guard let feature else { return [] }
        var values: [String] = []
        if let price = feature.priceYenEstimate { values.append("\(price)円前後") }
        if let room = feature.roomDescription { values.append(room) }
        values.append(contentsOf: feature.cuisineTags.prefix(2))
        return values
    }
}
