import SwiftUI

struct LoginSheet: View {
    let currentEmail: String?
    let onSignedIn: (String?) -> Void
    let onSignedOut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var isSigningOut = false
    @State private var errorMessage: String?

    var body: some View {
        BottomSheetScaffold(title: AppCopy.login) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if let currentEmail {
                    signedInView(email: currentEmail)
                } else {
                    loginForm
                }
                if let errorMessage {
                    InlineErrorView(message: errorMessage) {
                        self.errorMessage = nil
                    }
                }
            }
        }
        .accessibilityIdentifier("login-sheet")
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AppCopy.optionalLogin)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.ink.opacity(0.78))
            Text(AppCopy.loginCaveat)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.ink.opacity(0.78))
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(AppCopy.email).font(AppTypography.section)
                TextField("example@example.com", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .appInputFieldStyle()
                    .accessibilityIdentifier("login-email")
            }
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(AppCopy.password).font(AppTypography.section)
                SecureField("パスワードを入力", text: $password)
                    .appInputFieldStyle()
                    .accessibilityIdentifier("login-password")
            }
            PrimaryButton(title: AppCopy.loginSubmit, isLoading: isSubmitting) {
                Task { await signIn() }
            }
            .accessibilityIdentifier("login-submit")
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
        }
    }

    private func signedInView(email: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("ログイン中")
                .font(AppTypography.section)
            Text(email)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.ink.opacity(0.78))
            Button(isSigningOut ? AppCopy.loading : AppCopy.logout) {
                Task { await signOut() }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .buttonStyle(.bordered)
            .tint(AppColors.accent)
            .accessibilityIdentifier("logout")
            .disabled(isSigningOut)
        }
    }

    private func signIn() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let signedInEmail = try await Supa.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            onSignedIn(signedInEmail)
            dismiss()
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
        isSubmitting = false
    }

    private func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        errorMessage = nil
        do {
            try await Supa.signOutToAnonymous()
            onSignedOut()
            dismiss()
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
        isSigningOut = false
    }
}

#Preview {
    LoginSheet(currentEmail: nil, onSignedIn: { _ in }, onSignedOut: {})
}
