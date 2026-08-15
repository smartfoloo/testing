import SwiftUI

/// One row of the breakdown, already normalized so the view never has to think about
/// polarity: `value` is always higher-is-better. The burdens the engine stores (cost,
/// accessibility) reach the view as their `*_fit` component and are only ever spoken about
/// as 負担 in the prose, never drawn as a bar.
struct DimensionReading: Identifiable, Hashable {
    let dimension: ScoreDimension
    /// 0..1, higher is better. Meaningless when `isUnknown`.
    let value: Double
    /// The stored number is a missing-data placeholder (banded < 0.2), not a measurement.
    let isUnknown: Bool
    let isEmphasized: Bool
    let weight: Double?
    let contribution: Double?
    let evidence: String?

    var id: String { dimension.rawValue }

    static func readings(from breakdown: ScoreBreakdown) -> [DimensionReading] {
        let emphasized = Set(breakdown.emphasizedDimensions)
        return ScoreDimension.allCases.map { dimension in
            // A breakdown written by a newer version could omit a dimension this build knows.
            let component = breakdown.component(for: dimension)
            return DimensionReading(
                dimension: dimension,
                value: component ?? 0,
                isUnknown: component == nil || breakdown.isUnknown(dimension),
                isEmphasized: emphasized.contains(dimension),
                weight: breakdown.weight(for: dimension),
                contribution: breakdown.contribution(for: dimension),
                evidence: AppCopy.scoreDimensionEvidence(breakdown, dimension)
            )
        }
    }

    /// Fallback for rows written before 0016, which carry the flat columns but no breakdown.
    /// The dimensions those columns do cover are still shown — the rest is marked 未確認
    /// rather than drawn as a zero, and the weights are simply unknown.
    static func readings(fromFlat score: RecommendationScore) -> [DimensionReading] {
        func fit(_ burden: Double?) -> Double? { burden.map { 1 - $0 } }
        let values: [ScoreDimension: Double?] = [
            .travelFairness: score.fairnessScore,
            .travelAccess: nil,
            .satisfaction: score.satisfactionScore,
            .quality: score.qualityScore,
            .costFit: fit(score.costBurdenScore),
            .accessibilityFit: fit(score.accessibilityBurdenScore)
        ]
        return ScoreDimension.allCases.map { dimension in
            let value = values[dimension] ?? nil
            return DimensionReading(
                dimension: dimension,
                value: value ?? 0,
                isUnknown: value == nil,
                isEmphasized: false,
                weight: nil,
                contribution: nil,
                evidence: nil
            )
        }
    }
}

/// The 「この会で重視した項目」 marker, explained once in the list legend.
private struct EmphasisDot: View {
    var body: some View {
        Circle()
            .fill(AppColors.accent)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

private struct DimensionMeter: View {
    let reading: DimensionReading

    var body: some View {
        // Missing data gets an empty dashed track, never a short filled bar: the banded value
        // behind it says "we do not know", not "this venue scores badly".
        if reading.isUnknown {
            Capsule()
                .strokeBorder(AppColors.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 8)
                .accessibilityHidden(true)
        } else {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColors.ink.opacity(0.08))
                    Capsule()
                        .fill(AppColors.accent)
                        .frame(width: proxy.size.width * min(1, max(0, reading.value)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
    }
}

private struct DimensionCell: View {
    let reading: DimensionReading

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xxs) {
                if reading.isEmphasized { EmphasisDot() }
                Text(reading.dimension.label)
                    .font(reading.isEmphasized ? AppTypography.small.weight(.semibold) : AppTypography.small)
                    .foregroundStyle(reading.isEmphasized ? AppColors.ink : AppColors.ink.opacity(0.72))
                Spacer(minLength: AppSpacing.xxs)
                Text(reading.isUnknown ? ScoreCopy.unknown : AppCopy.scorePercent(reading.value))
                    .font(reading.isUnknown ? AppTypography.small : AppTypography.small.weight(.semibold))
                    .foregroundStyle(reading.isUnknown ? AppColors.ink.opacity(0.72) : AppColors.ink)
                    .accessibilityIdentifier("dimension-value-\(reading.dimension.rawValue)")
            }
            DimensionMeter(reading: reading)
        }
        .accessibilityIdentifier("dimension-\(reading.dimension.rawValue)")
    }
}

/// Progressive disclosure: the six meters stay visible so two cards can be compared at a
/// glance, and the arithmetic plus the evidence sentences are one tap away.
private struct ScoreBreakdownView: View {
    let readings: [DimensionReading]
    let gapNote: String?
    /// Nil for legacy rows: without stored weights there is no arithmetic to expand into.
    let objectiveScore: Double?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: AppSpacing.sm)], spacing: AppSpacing.xs) {
                ForEach(readings) { reading in
                    DimensionCell(reading: reading)
                }
            }
            if let gapNote {
                Label(gapNote, systemImage: "exclamationmark.circle")
                    .font(AppTypography.small)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .accessibilityIdentifier("score-data-gaps")
            }
            if let objectiveScore {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Text(isExpanded ? ScoreCopy.hideDetail : ScoreCopy.showDetail)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppColors.accent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("score-breakdown-toggle")
                if isExpanded {
                    detail(objectiveScore: objectiveScore)
                }
            }
        }
        .padding(AppSpacing.sm)
        .background(AppColors.background)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .accessibilityIdentifier("score-breakdown")
    }

    private func detail(objectiveScore: Double) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(ScoreCopy.scaleNote)
                .font(AppTypography.small)
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .accessibilityIdentifier("score-scale-note")
            ForEach(readings) { reading in
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Divider().overlay(AppColors.border)
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                        if reading.isEmphasized { EmphasisDot() }
                        Text(reading.dimension.label).font(AppTypography.caption.weight(.semibold))
                        Spacer(minLength: AppSpacing.xxs)
                        if let weight = reading.weight, let contribution = reading.contribution {
                            Text(AppCopy.scoreContribution(weight: weight, contribution: contribution))
                                .font(AppTypography.small)
                                .foregroundStyle(AppColors.ink.opacity(0.72))
                        }
                    }
                    if let evidence = reading.evidence {
                        Text(evidence)
                            .font(AppTypography.small)
                            .foregroundStyle(AppColors.ink.opacity(0.72))
                    }
                }
                .accessibilityIdentifier("dimension-detail-\(reading.dimension.rawValue)")
            }
            Divider().overlay(AppColors.border)
            Text(AppCopy.scoreWeightedTotal(objectiveScore))
                .font(AppTypography.small)
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .accessibilityIdentifier("objective-score-total")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ScoreCopy.detailAccessibilityLabel)
        .accessibilityIdentifier("score-breakdown-detail")
    }
}

struct RecommendationCardView: View {
    let score: RecommendationScore
    let feature: RestaurantFeature?
    let explanation: String?
    let isExplaining: Bool
    let isOrganizer: Bool
    let isChosen: Bool
    let isChoosing: Bool
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
                    Text(score.label?.badge ?? AppCopy.recommendationBadge(nil))
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
                // PRD §9: no single opaque AI score. Every dimension is named, with the
                // emphasis this event's objective put on it and an explicit 未確認 where the
                // data behind it is missing.
                ScoreBreakdownView(
                    readings: readings,
                    gapNote: score.scoreBreakdown.flatMap { AppCopy.scoreDataGapNote($0) },
                    objectiveScore: score.scoreBreakdown?.objectiveScore
                )
                if isOrganizer && !isChosen {
                    PrimaryButton(title: "このお店に決める", systemImage: "checkmark", isLoading: isChoosing) { onChoose() }
                        .accessibilityIdentifier("choose-restaurant")
                        .disabled(isChoosing)
                } else if isChosen {
                    Text(AppCopy.chosen)
                        .font(AppTypography.body.weight(.bold))
                        .foregroundStyle(AppColors.accent)
                }
            }
            .accessibilityIdentifier("recommendation-card-\(score.restaurantPlaceId)")
        }
    }

    private var readings: [DimensionReading] {
        if let breakdown = score.scoreBreakdown {
            return DimensionReading.readings(from: breakdown)
        }
        return DimensionReading.readings(fromFlat: score)
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
