import Foundation
import Supabase

enum SupabaseConfig {
    /// Values are read from Info.plist (`SUPABASE_URL`, `SUPABASE_ANON_KEY`), which
    /// are populated from the `SUPABASE_URL` / `SUPABASE_ANON_KEY` build settings.
    static let url: URL = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let url = URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)")
        else { fatalError("SUPABASE_URL is missing from Info.plist") }
        return url
    }()

    static let anonKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              !key.isEmpty
        else { fatalError("SUPABASE_ANON_KEY is missing from Info.plist") }
        return key
    }()
}

enum Supa {
    static let client = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)

    /// Signs in anonymously when no session has been persisted by the SDK's storage layer.
    /// UI tests pass `-AIKanjiResetSession` to act as a brand-new person on each launch.
    static func ensureSession() async throws {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AIKanjiResetSession") {
            try? await client.auth.signOut()
        }
#endif
        if (try? await client.auth.session) != nil {
            return
        }
        _ = try await client.auth.signInAnonymously()
    }

    static func currentEmail() async -> String? {
        guard let session = try? await client.auth.session else { return nil }
        return session.user.email
    }

    static func signIn(email: String, password: String) async throws -> String? {
        let session = try await client.auth.signIn(email: email, password: password)
        return session.user.email
    }

    static func signOutToAnonymous() async throws {
        try await client.auth.signOut()
        _ = try await client.auth.signInAnonymously()
    }
}
