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
                .alert("ログインに失敗しました", isPresented: .constant(authError != nil)) {
                    Button("閉じる") { authError = nil }
                } message: {
                    Text(authError ?? "")
                }
        }
    }
}
