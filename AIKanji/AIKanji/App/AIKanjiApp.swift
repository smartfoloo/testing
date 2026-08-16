import SwiftUI

@main
struct AIKanjiApp: App {
    @State private var isSessionReady = false
    @State private var isAuthenticating = false
    @State private var authError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if isSessionReady {
                    WelcomeView()
                } else {
                    ZStack {
                        AppColors.background.ignoresSafeArea()
                        VStack(spacing: AppSpacing.md) {
                            if isAuthenticating {
                                ProgressView()
                                Text("セッションを準備しています")
                                    .font(AppTypography.body)
                                    .foregroundStyle(AppColors.ink.opacity(0.72))
                            } else {
                                Text(authError ?? AppCopy.networkError)
                                    .font(AppTypography.body)
                                    .multilineTextAlignment(.center)
                                Button(AppCopy.retry) {
                                    Task { await prepareSession() }
                                }
                                .font(AppTypography.body.weight(.bold))
                                .foregroundStyle(AppColors.accentForeground)
                                .frame(minHeight: 44)
                                .padding(.horizontal, AppSpacing.lg)
                                .background(AppColors.accent)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(AppSpacing.xl)
                    }
                }
            }
            .task { await prepareSession() }
        }
    }

    @MainActor
    private func prepareSession() async {
        guard !isSessionReady, !isAuthenticating else { return }
        isAuthenticating = true
        authError = nil
        do {
            try await Supa.ensureSession()
            isSessionReady = true
        } catch {
            authError = AppCopy.errorMessage(for: error)
        }
        isAuthenticating = false
    }
}
