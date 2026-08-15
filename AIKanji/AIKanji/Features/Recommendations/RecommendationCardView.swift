import SwiftUI

struct RecommendationCardView: View {
    let score: RecommendationScore
    let feature: RestaurantFeature?
    let explanation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let label = score.label {
                    Text(label.badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }

            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let explanation {
                Text(explanation).font(.body)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Writing a summary…").font(.footnote).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                scorePill("Fair", score.fairnessScore)
                scorePill("Match", score.satisfactionScore)
                scorePill("Quality", score.qualityScore)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var title: String {
        feature?.cuisineTags.first?.capitalized ?? score.restaurantPlaceId
    }

    private var details: [String] {
        guard let feature else { return [] }
        var parts: [String] = []
        if let price = feature.priceYenEstimate { parts.append("¥\(price)") }
        if let room = feature.roomDescription { parts.append(room) }
        parts.append(contentsOf: feature.atmosphereTags.prefix(2))
        return parts
    }

    @ViewBuilder
    private func scorePill(_ name: String, _ value: Double?) -> some View {
        if let value {
            VStack(spacing: 2) {
                Text(name).font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.2f", value)).font(.caption.monospacedDigit())
            }
        }
    }
}
