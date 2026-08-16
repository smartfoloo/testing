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
    ///
    /// A persisted session is proven against the server, not trusted. A session can outlive
    /// its user — an auth reset in development, a revoked session in production — and the SDK
    /// hands back the cached tokens regardless: everything works until the access token
    /// expires, and from then on every call answers 401 while refresh can never succeed. One
    /// refresh here turns that from an unrecoverable mid-session death into a fresh anonymous
    /// sign-in at the next launch. A refresh that fails because the server cannot be REACHED
    /// keeps the stored session — offline is not evidence that the identity is gone.
    static func ensureSession() async throws {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AIKanjiResetSession") {
            try? await client.auth.signOut()
        }
#endif
        if (try? await client.auth.session) != nil {
            do {
                _ = try await client.auth.refreshSession()
                return
            } catch is AuthError {
                // The server answered and said no: the identity behind the stored session is
                // gone. Clear the remains so the sign-in below starts clean.
                try? await client.auth.signOut()
            } catch {
                return
            }
        }
        _ = try await client.auth.signInAnonymously()
    }

    static func currentEmail() async -> String? {
        guard let session = try? await client.auth.session else { return nil }
        return authenticatedEmail(from: session)
    }

    static func signIn(email: String, password: String) async throws -> String? {
        let session = try await client.auth.signIn(email: email, password: password)
        return authenticatedEmail(from: session)
    }

    static func signOutToAnonymous() async throws {
        try await client.auth.signOut()
        _ = try await client.auth.signInAnonymously()
    }

    private static func authenticatedEmail(from session: Session) -> String? {
        guard !session.user.isAnonymous,
              let email = session.user.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else {
            return nil
        }
        return email
    }
}
