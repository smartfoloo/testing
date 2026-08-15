import SwiftUI

struct WelcomeView: View {
    @State private var isLoginPresented = false
    @State private var signedInEmail: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()
                Circle().fill(AppColors.accentSoft).frame(width: 220, height: 220).offset(x: 150, y: -310)
                Circle().fill(AppColors.greenSoft).frame(width: 170, height: 170).offset(x: -170, y: 300)
                VStack(spacing: AppSpacing.xl) {
                    Spacer()
                    VStack(spacing: AppSpacing.sm) {
                        Text(AppCopy.appName).font(AppTypography.display).foregroundStyle(AppColors.ink)
                        Text("みんなの予定を、ひとつに")
                            .font(AppTypography.caption.weight(.bold))
                            .foregroundStyle(AppColors.accent)
                    }
                    Text(AppCopy.tagline)
                        .font(AppTypography.body.weight(.medium))
                        .foregroundStyle(AppColors.ink)
                        .multilineTextAlignment(.center)
                    VStack(spacing: AppSpacing.sm) {
                        NavigationLink {
                            CreateEventView()
                        } label: {
                            Text(AppCopy.create).frame(maxWidth: .infinity).frame(minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.accent)
                        .clipShape(Capsule())
                        .accessibilityIdentifier("create-event")

                        NavigationLink {
                            JoinEventView()
                        } label: {
                            Text(AppCopy.join).frame(maxWidth: .infinity).frame(minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.ink)
                        .background(AppColors.card)
                        .overlay(Capsule().strokeBorder(AppColors.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                        .clipShape(Capsule())
                        .accessibilityIdentifier("join-event")
                    }
                    VStack(spacing: AppSpacing.xs) {
                        Button(AppCopy.login) {
                            isLoginPresented = true
                        }
                        .font(AppTypography.body.weight(.semibold))
                        .foregroundStyle(AppColors.accent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("login")
                        Text(AppCopy.optionalLogin)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.ink.opacity(0.72))
                            .multilineTextAlignment(.center)
                        if let signedInEmail {
                            Text(signedInEmail)
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColors.ink.opacity(0.72))
                                .accessibilityIdentifier("signed-in-email")
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.lg)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            signedInEmail = await Supa.currentEmail()
        }
        .sheet(isPresented: $isLoginPresented) {
            LoginSheet(
                currentEmail: signedInEmail,
                onSignedIn: { signedInEmail = $0 },
                onSignedOut: { signedInEmail = nil }
            )
        }
    }
}

#Preview { WelcomeView() }
