import SwiftUI

struct AppInputFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: 48)
            .background(AppColors.card)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous)
                    .stroke(AppColors.border, lineWidth: 1)
            )
    }
}

extension View {
    func appInputFieldStyle() -> some View {
        modifier(AppInputFieldStyle())
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                if isLoading {
                    ProgressView()
                        .tint(AppColors.accentForeground)
                        .accessibilityHidden(true)
                }
                if let systemImage, !isLoading { Image(systemName: systemImage) }
                Text(title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(AppTypography.body.weight(.bold))
            .foregroundStyle(AppColors.accentForeground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .padding(.vertical, AppSpacing.xxs)
        }
        .buttonStyle(.plain)
        .background(AppColors.accent)
        .clipShape(Capsule())
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? AppCopy.loading : "")
        .accessibilityIdentifier("primary-\(title)")
        .disabled(isLoading)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(AppTypography.body.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xxs)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppColors.ink)
        .background(AppColors.card)
        .overlay(Capsule().strokeBorder(AppColors.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .clipShape(Capsule())
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }
}

struct SelectionChip: View {
    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(AppTypography.body.weight(.semibold))
        .foregroundStyle(isSelected ? AppColors.accentForeground : AppColors.ink)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.xxs)
        .frame(minHeight: 44)
        .background(isSelected ? AppColors.accent : AppColors.card)
        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : AppColors.border))
        .clipShape(Capsule())
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "選択中" : "未選択")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct StarterChip: View {
    let title: String
    let tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, AppSpacing.xs)
                .background(tint)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .font(AppTypography.caption.weight(.semibold))
        .foregroundStyle(AppColors.warmForeground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(title)
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(AppSpacing.md)
            .background(AppColors.card)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .shadow(color: AppColors.ink.opacity(0.08), radius: 10, y: 3)
    }
}

struct StatTile: View {
    let value: String
    let title: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(value).font(AppTypography.display)
            Text(title).font(AppTypography.caption).foregroundStyle(AppColors.ink.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct BottomSheetScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Capsule().fill(AppColors.ink.opacity(0.2)).frame(width: 42, height: 5)
            Text(title).font(AppTypography.title).frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

#Preview("Primitives") {
    ScrollView {
        VStack(spacing: 16) {
            PrimaryButton(title: "お店を探す", systemImage: "sparkles", action: {})
            SecondaryButton(title: "おすすめを見る", systemImage: "arrow.right", action: {})
            HStack {
                SelectionChip(title: "バランス", isSelected: true, action: {})
                StarterChip(title: "個室", tint: AppColors.accentSoft, action: {})
            }
            AppCard { Text("まとメシ").font(AppTypography.title) }
            StatTile(value: "3", title: "回答数", tint: AppColors.card)
        }
        .padding()
    }
    .background(AppColors.background)
    .environment(\.dynamicTypeSize, .accessibility3)
}
