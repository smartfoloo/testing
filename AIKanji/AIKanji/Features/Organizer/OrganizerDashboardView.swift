import Foundation
import SwiftUI

@MainActor
final class OrganizerDashboardViewModel: ObservableObject {
    @Published var responseCount = 0
    @Published var feasibleCount: Int?
    @Published var openNegotiations = 0
    @Published var latestRunId: UUID?
    @Published var isWorking = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    private let service: NegotiationService
    init(service: NegotiationService = NegotiationService()) { self.service = service }
    var negotiationInProgress: Bool { openNegotiations > 0 }

    func load(eventId: UUID) async {
        do {
            responseCount = try await service.responseCount(eventId: eventId)
            openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
            if let run = try await service.latestRun(eventId: eventId) {
                feasibleCount = run.feasibleCount
                latestRunId = run.id
            }
        } catch { errorMessage = AppCopy.networkError }
    }

    func listenForRuns(eventId: UUID) async {
        do {
            let (channel, stream) = try await service.runUpdates(eventId: eventId)
            defer { Task { await Supa.client.removeChannel(channel) } }
            for await update in stream {
                feasibleCount = update.feasibleCount
                latestRunId = update.runId
                do {
                    openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
                    responseCount = try await service.responseCount(eventId: eventId)
                } catch {
                    errorMessage = AppCopy.networkError
                }
            }
        } catch { errorMessage = AppCopy.networkError }
    }

    func findRestaurants(eventId: UUID) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        do {
            let candidates = try await service.findRestaurants(eventId: eventId)
            let result = try await service.recomputeFeasibility(eventId: eventId)
            feasibleCount = result.feasibleCount
            latestRunId = result.runId
            if result.feasibleCount == 0 {
                statusMessage = try await service.proposeRelaxation(eventId: eventId) == nil
                    ? "今の条件では、まだ候補が見つかりません。みんなで相談してみましょう。"
                    : "条件に合うお店がありません。参加者に条件の変更をお願いしました。"
                do {
                    openNegotiations = try await service.pendingNegotiationCount(eventId: eventId)
                } catch {
                    errorMessage = AppCopy.networkError
                }
            } else if candidates == 0 {
                statusMessage = "以前に取得した候補を表示しています。"
            }
        } catch { errorMessage = AppCopy.networkError }
        isWorking = false
    }
}

struct OrganizerDashboardView: View {
    let eventId: UUID
    @Binding var decision: EventDecision?
    @StateObject private var viewModel = OrganizerDashboardViewModel()
    @State private var openRunId: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(AppCopy.homeOrganizer).font(AppTypography.title)
                    Text("みんなの条件を集計して、お店を探します。")
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                }
                HStack(spacing: AppSpacing.sm) {
                    StatTile(value: "\(viewModel.responseCount)", title: "回答数", tint: AppColors.card)
                    StatTile(value: viewModel.feasibleCount.map(String.init) ?? "—", title: "条件を満たすお店", tint: (viewModel.feasibleCount ?? 0) > 0 ? AppColors.accentSoft : AppColors.card)
                }
                if viewModel.negotiationInProgress {
                    Text("調整中…").font(AppTypography.caption.weight(.bold))
                        .foregroundStyle(AppColors.ink).padding(.horizontal, AppSpacing.md).frame(minHeight: 36)
                        .background(AppColors.yellow).clipShape(Capsule())
                }
                PrimaryButton(title: AppCopy.findRestaurants, isLoading: viewModel.isWorking) {
                    Task { await viewModel.findRestaurants(eventId: eventId) }
                }
                .accessibilityIdentifier("find-restaurants")
                if let runId = viewModel.latestRunId, (viewModel.feasibleCount ?? 0) > 0 {
                    Button("おすすめを見る") { openRunId = runId }
                        .frame(maxWidth: .infinity).frame(minHeight: 48)
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.ink)
                        .background(AppColors.card)
                        .overlay(Capsule().strokeBorder(AppColors.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                        .clipShape(Capsule())
                        .accessibilityIdentifier("recommendations")
                }
                if decision?.chosenPlaceId != nil {
                    AppCard {
                        Label(AppCopy.chosen, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(AppColors.accent)
                    }
                }
                Text("誰がどの条件を出したかは表示せず、集計結果だけを共有します。")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage).font(AppTypography.body)
                }
                if let errorMessage = viewModel.errorMessage {
                    InlineErrorView(message: errorMessage) { Task { await viewModel.load(eventId: eventId) } }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .navigationDestination(item: $openRunId) { runId in
            RecommendationListView(runId: runId, eventId: eventId, onChosen: { decision = $0 })
        }
        .task { await viewModel.load(eventId: eventId) }
        .task { await viewModel.listenForRuns(eventId: eventId) }
    }
}
