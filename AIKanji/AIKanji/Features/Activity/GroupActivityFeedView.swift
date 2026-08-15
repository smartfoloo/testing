import Supabase
import SwiftUI

struct GroupActivityFeedView: View {
    let eventId: UUID
    private let service = ConstraintService()
    @State private var items: [FeedItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    #if DEBUG
    @State private var lastPayload: String?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(AppCopy.homeGroup).font(AppTypography.title)
                    Text("共有された希望だけが、ここに表示されます。")
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                }
                if isLoading {
                    LoadingStateView(title: "みんなの状況を読み込んでいます")
                } else if items.isEmpty {
                    EmptyStateView(title: "まだ共有された希望はありません", message: "希望が保存されると、ここに表示されます。")
                } else {
                    ForEach(items) { item in
                        AppCard {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                HStack {
                                    Text(item.displayName ?? "匿名の参加者")
                                        .font(AppTypography.caption.weight(.bold))
                                    Spacer()
                                    Text(item.kind.title)
                                        .font(AppTypography.small.weight(.bold))
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
                #if DEBUG
                if let lastPayload {
                    AppCard {
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text("デバッグ：最後に受け取った共有データ")
                                .font(AppTypography.caption.weight(.bold))
                            Text(lastPayload)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                #endif
                if let errorMessage {
                    InlineErrorView(message: errorMessage) { Task { await listen() } }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .task { await listen() }
    }

    private func listen() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await service.sanitizedFeed(eventId: eventId)
            let (channel, stream) = try await service.constraintBroadcasts(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            isLoading = false
            for await (item, payload) in stream {
                #if DEBUG
                lastPayload = Self.describe(payload)
                #endif
                if !items.contains(where: { $0.id == item.id }) { items.append(item) }
            }
        } catch {
            isLoading = false
            errorMessage = AppCopy.networkError
        }
    }

    #if DEBUG
    private static func describe(_ payload: [String: AnyJSON]) -> String {
        payload.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.isNil ? "null" : String(describing: $0.value.value))" }
            .joined(separator: "\n")
    }
    #endif
}
