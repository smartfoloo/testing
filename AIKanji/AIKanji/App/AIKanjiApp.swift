import SwiftUI

@main
struct AIKanjiApp: App {
    @State private var authError: String?

    var body: some Scene {
        WindowGroup {
            WelcomeView()
                .task {
                    do {
                        try await Supa.ensureSession()
                    } catch {
                        authError = error.localizedDescription
                    }
                }
                .alert("Sign-in failed", isPresented: .constant(authError != nil)) {
                    Button("OK") { authError = nil }
                } message: {
                    Text(authError ?? "")
                }
        }
    }
}
