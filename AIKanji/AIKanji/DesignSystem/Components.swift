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

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                if isLoading { ProgressView().tint(.white) }
                if let systemImage, !isLoading { Image(systemName: systemImage) }
                Text(isLoading ? AppCopy.loading : title)
            }
            .font(AppTypography.body.weight(.bold))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppColors.accent)
        .clipShape(Capsule())
        .accessibilityIdentifier("primary-\(title)")
        .disabled(isLoading)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(AppTypography.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppColors.ink)
        .background(AppColors.card)
        .overlay(Capsule().strokeBorder(AppColors.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .clipShape(Capsule())
    }
}

struct SelectionChip: View {
    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(AppTypography.body.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : AppColors.ink)
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: 44)
            .background(isSelected ? AppColors.accent : AppColors.card)
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : AppColors.border))
            .clipShape(Capsule())
    }
}

struct StarterChip: View {
    let title: String
    let tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 48)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, AppSpacing.xs)
                .background(tint)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .font(AppTypography.caption.weight(.semibold))
        .foregroundStyle(AppColors.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
