import SwiftUI

struct LoadingStateView: View {
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            RoundedRectangle(cornerRadius: 8).fill(AppColors.ink.opacity(0.08)).frame(height: 18)
            RoundedRectangle(cornerRadius: 8).fill(AppColors.ink.opacity(0.06)).frame(height: 14)
            RoundedRectangle(cornerRadius: 8).fill(AppColors.ink.opacity(0.06)).frame(height: 14)
            Text(title).font(AppTypography.caption).foregroundStyle(AppColors.ink.opacity(0.72))
        }
        .redacted(reason: .placeholder)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppColors.card)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .accessibilityLabel(title)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "text.bubble")
                .font(.title)
                .foregroundStyle(AppColors.accent)
            Text(title).font(AppTypography.section)
            Text(message).font(AppTypography.body)
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxl)
    }
}

struct InlineErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.ink)
            Button(AppCopy.retry, action: retry)
                .font(AppTypography.body.weight(.bold))
                .foregroundStyle(AppColors.accent)
                .frame(minHeight: 44)
        }
        .padding(AppSpacing.md)
        .background(AppColors.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

#Preview("States") {
    VStack {
        LoadingStateView(title: "読み込んでいます")
        EmptyStateView(title: "まだありません", message: "条件が共有されると、ここに表示されます。")
        InlineErrorView(message: "通信できませんでした。", retry: {})
    }
    .padding()
    .background(AppColors.background)
    .preferredColorScheme(.dark)
}
