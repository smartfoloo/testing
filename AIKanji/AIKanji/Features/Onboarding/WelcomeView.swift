import SwiftUI

struct WelcomeView: View {
    /// Set when the app was opened by an invite link, which pushes the join screen with the
    /// code prefilled (PRD §3).
    @State private var linkedInviteCode: String?

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
                    Spacer()
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.lg)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $linkedInviteCode) { code in
                JoinEventView(initialCode: code)
            }
            // An invite link carries the code as `?code=`; the same parser also accepts a bare
            // code or a trailing path component, so a scanned QR and a tapped link agree.
            // Note: for an https link to reach this handler the invite domain still needs the
            // Associated Domains entitlement and an apple-app-site-association file.
            .onOpenURL { url in
                let code = JoinEventView.extractInviteCode(from: url.absoluteString)
                if code.count == 6 { linkedInviteCode = code }
            }
        }
    }
}

#Preview { WelcomeView() }
