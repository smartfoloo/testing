import SwiftUI

struct GroupActivityFeedView: View {
    let eventId: UUID
    let progress: EventProgress?
    private let service = ConstraintService()
    @State private var items: [FeedItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var retryAttempt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    if let progress {
                        Text("\(progress.participantCount)人参加・\(progress.completedCount)人回答あり")
                            .font(AppTypography.section)
                            .accessibilityIdentifier("group-response-progress")
                    }
                    Text(AppCopy.homeGroup).font(AppTypography.title)
                    Text("共有された希望だけが、ここに表示されます。")
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                }
                if isLoading {
                    LoadingStateView(title: "みんなの希望を読み込んでいます")
                } else if items.isEmpty {
                    EmptyStateView(title: "まだ共有された希望はありません", message: "希望が保存されると、ここに表示されます。")
                } else {
                    ForEach(items) { item in
                        AppCard {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(item.displayName ?? "匿名の参加者")
                                        .font(AppTypography.caption.weight(.bold))
                                    Text(item.kind.title)
                                        .font(AppTypography.small.weight(.bold))
                                        .foregroundStyle(item.kind == .must ? AppColors.ink : AppColors.warmForeground)
                                        .padding(.horizontal, AppSpacing.sm)
                                        .padding(.vertical, AppSpacing.xxs)
                                        .background(item.kind == .must ? AppColors.accentSoft : AppColors.yellow)
                                        .clipShape(Capsule())
                                }
                                Text(ConstraintFormatter.summary(type: item.normalizedType, value: item.normalizedValue))
                                    .font(AppTypography.body)
                            }
                        }
                    }
                }
                if let errorMessage {
                    InlineErrorView(message: errorMessage) { retryAttempt += 1 }
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .task(id: retryAttempt) { await listen() }
    }

    @MainActor
    private func listen() async {
        isLoading = items.isEmpty
        errorMessage = nil
        do {
            let (channel, stream) = try await service.constraintBroadcasts(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            try await reload()
            isLoading = false
            for await _ in stream {
                do {
                    try await reload()
                    errorMessage = nil
                } catch {
                    errorMessage = AppCopy.errorMessage(for: error)
                }
            }
        } catch {
            isLoading = false
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    @MainActor
    private func reload() async throws {
        items = try await service.sanitizedFeed(eventId: eventId)
            .sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            }
    }
}
