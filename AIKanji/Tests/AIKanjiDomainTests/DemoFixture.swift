import Foundation
import Supabase
import XCTest

/// Shared configuration + fixture reset for the domain tests. Everything is read from
/// the environment so no key is committed:
///
///   TEST_RUNNER_SUPABASE_URL, TEST_RUNNER_SUPABASE_ANON_KEY,
///   TEST_RUNNER_SUPABASE_SERVICE_ROLE_KEY, TEST_RUNNER_AIKANJI_TEST_PASSWORD
///
/// The service-role key is used only to reset the seeded fixture between tests (RLS
/// deliberately makes that impossible for any participant) — never to exercise a
/// behaviour under test.
enum DemoFixture {
    static let eventId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let alice = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    static let bob = UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!
    static let charlie = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
    static let emma = UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!

    enum Persona: String {
        case alice, bob, charlie, david, emma
        var email: String { "\(rawValue)@aikanji.demo" }
    }

    struct MissingConfiguration: Error, CustomStringConvertible {
        let key: String
        var description: String { "missing environment variable \(key)" }
    }

    static func env(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw MissingConfiguration(key: key)
        }
        return value
    }

    static var projectURL: URL {
        get throws {
            // Accepts a bare host too: xcodebuild collapses `//` when forwarding
            // environment values to the test runner.
            var raw = try env("SUPABASE_URL").trimmingCharacters(in: .whitespacesAndNewlines)
            if let host = raw.split(separator: "/").last, !raw.hasPrefix("https://") {
                raw = "https://\(host)"
            }
            guard let url = URL(string: raw), url.host != nil else {
                throw MissingConfiguration(key: "SUPABASE_URL (got \"\(raw)\")")
            }
            return url
        }
    }

    /// A client whose session belongs to `persona`, so every read runs under that
    /// participant's RLS policies.
    static func client(as persona: Persona) async throws -> SupabaseClient {
        let client = SupabaseClient(
            supabaseURL: try projectURL,
            supabaseKey: try env("SUPABASE_ANON_KEY"),
            options: .init(auth: .init(storage: InMemoryAuthStorage()))
        )
        _ = try await client.auth.signIn(
            email: persona.email,
            password: try env("AIKANJI_TEST_PASSWORD")
        )
        return client
    }

    /// Restores the fixture to its seeded state: Bob's room MUST back to `private`,
    /// no negotiations, no recommendation runs.
    static func reset() async throws {
        try await admin("DELETE", "negotiations?event_id=eq.\(eventId.uuidString.lowercased())")
        try await admin("DELETE", "recommendation_runs?event_id=eq.\(eventId.uuidString.lowercased())")
        try await admin(
            "PATCH",
            "participant_constraints?participant_id=eq.\(bob.uuidString.lowercased())&normalized_type=eq.room",
            body: ["normalized_value": ["room": "private"]]
        )
    }

    static func deleteEvent(_ id: UUID) async throws {
        try await admin("DELETE", "events?id=eq.\(id.uuidString.lowercased())")
    }

    /// Reads a negotiation row with the service role. Used only to assert what the
    /// engine wrote — no participant and no organizer can read this.
    static func negotiationRow(eventId: UUID) async throws -> [String: Any]? {
        let data = try await admin(
            "GET",
            "negotiations?event_id=eq.\(eventId.uuidString.lowercased())&select=participant_id,constraint_id,proposed_value,unlocked_count,status"
        )
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return rows?.first
    }

    static func constraintType(id: UUID) async throws -> String? {
        let data = try await admin(
            "GET",
            "participant_constraints?id=eq.\(id.uuidString.lowercased())&select=normalized_type"
        )
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return rows?.first?["normalized_type"] as? String
    }

    @discardableResult
    private static func admin(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil
    ) async throws -> Data {
        let key = try env("SUPABASE_SERVICE_ROLE_KEY")
        // Built from a string: appendingPathComponent would percent-encode the query.
        guard let url = URL(string: "\(try projectURL.absoluteString)/rest/v1/\(path)") else {
            throw MissingConfiguration(key: "SUPABASE_URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "DemoFixture",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) failed: \(String(decoding: data, as: UTF8.self))"]
            )
        }
        return data
    }
}

/// Keeps each persona's session out of the shared keychain/user-defaults storage so
/// the five sessions in a single test run never overwrite each other.
final class InMemoryAuthStorage: AuthLocalStorage {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.withLock { values[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func remove(key: String) throws {
        lock.withLock { values[key] = nil }
    }
}
