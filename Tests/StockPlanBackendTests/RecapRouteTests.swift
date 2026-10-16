import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Recap routes", .serialized)
struct RecapRouteTests {
    private struct SlideProbe: Decodable { let type: String }
    private struct DeckProbe: Decodable { let slides: [SlideProbe] }
    private struct ResponseProbe: Decodable { let id: UUID; let deck: DeckProbe }

    /// Runs `body` with the recap flags set, restoring the previous values afterwards.
    private func withFlags(
        enabled: String? = "true", yearly: String? = nil, _ body: () async throws -> Void
    ) async throws {
        let names = ["RECAP_ENABLED", "RECAP_YEARLY_ENABLED"]
        let saved = names.map { getenv($0).map { String(cString: $0) } }
        defer {
            for (name, value) in zip(names, saved) {
                if let value {
                    setenv(name, value, 1)
                } else {
                    unsetenv(name)
                }
            }
        }
        for (name, value) in zip(names, [enabled, yearly]) {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
        try await body()
    }

    private func send(
        _ app: Application, _ method: HTTPMethod, _ path: String, token: String?,
        _ check: @escaping (TestingHTTPResponse) async throws -> Void
    ) async throws {
        try await app.testing().test(method, path, beforeRequest: { req in
            if let token {
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }
        }, afterResponse: check)
    }

    private func lastMonthKey() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = RecapFixtures.utc
        let last = cal.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let parts = cal.dateComponents([.year, .month], from: last)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func currentMonthKey() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = RecapFixtures.utc
        let parts = cal.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func mintPAT(_ app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        try await PersonalAccessToken(
            userId: userId, name: "recap-test", tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue), expiresAt: Date().addingTimeInterval(3600)
        ).save(on: app.db)
        return raw
    }

    /// Forces the user's `created_at` to two months ago so last month is available.
    private func makeOld(_ app: Application, _ userId: UUID) async throws {
        try await RecapFixtures.backdate(
            table: "users", id: userId, to: Date().addingTimeInterval(-70 * 86400), on: app.db
        )
    }

    @Test("Flag off answers 404 on every route")
    func disabledIs404() async throws {
        try await withFlags(enabled: nil) {
            try await RecapFixtures.withUser { app, token, userId in
                let id = UUID().uuidString
                let routes: [(HTTPMethod, String)] = [
                    (.GET, "v1/recaps"), (.GET, "v1/recaps/month/2026-01"),
                    (.POST, "v1/recaps/\(id)/opened"), (.POST, "v1/recaps/\(id)/completed"),
                ]
                // The flag check runs before auth: no token is 404, not 401.
                for authToken in [token, nil] as [String?] {
                    for (method, path) in routes {
                        try await send(app, method, path, token: authToken) { res in
                            #expect(res.status == .notFound, "\(method) \(path) token: \(authToken != nil)")
                        }
                    }
                }
                // A read-only token on a write route is 404, not 403.
                let readOnly = try await mintPAT(app, userId: userId, scopes: [.planningRead])
                for path in ["v1/recaps/\(id)/opened", "v1/recaps/\(id)/completed"] {
                    try await send(app, .POST, path, token: readOnly) { res in
                        #expect(res.status == .notFound, "\(path)")
                    }
                }
            }
        }
    }

    @Test("With the flag on a read-only token can read but not write")
    func readOnlyTokenCannotWrite() async throws {
        try await withFlags {
            try await RecapFixtures.withUser { app, _, userId in
                let readOnly = try await mintPAT(app, userId: userId, scopes: [.planningRead])
                try await send(app, .GET, "v1/recaps", token: readOnly) { #expect($0.status == .ok) }
                try await send(app, .POST, "v1/recaps/\(UUID().uuidString)/opened", token: readOnly) { res in
                    #expect(res.status == .forbidden)
                }
            }
        }
    }

    @Test("No token is 401")
    func unauthenticatedIs401() async throws {
        try await withFlags {
            try await RecapFixtures.withApp { app in
                try await send(app, .GET, "v1/recaps", token: nil) { #expect($0.status == .unauthorized) }
            }
        }
    }

    @Test("A brand-new user gets the missed-you deck")
    func brandNewUserGetsMissedYou() async throws {
        try await withFlags {
            try await RecapFixtures.withUser { app, token, userId in
                try await makeOld(app, userId)
                try await send(app, .GET, "v1/recaps/month/\(lastMonthKey())", token: token) { res in
                    #expect(res.status == .ok)
                    let probe = try res.content.decode(ResponseProbe.self)
                    #expect(probe.deck.slides.map(\.type) == ["intro", "missed_you", "outro"])
                }
            }
        }
    }

    @Test("Bad kinds, bad keys and unavailable periods are 404")
    func badKeysAre404() async throws {
        try await withFlags {
            try await RecapFixtures.withUser { app, token, userId in
                try await makeOld(app, userId)
                for path in [
                    "month/2026-13", "week/2026-10", "month/\(currentMonthKey())", "year/0000", "month/9999-01", "year/2026",
                ] {
                    try await send(app, .GET, "v1/recaps/\(path)", token: token) { res in
                        #expect(res.status == .notFound, "\(path)")
                    }
                }
            }
        }
    }

    @Test("Opened then completed stamps both timestamps")
    func openedThenCompleted() async throws {
        try await withFlags {
            try await RecapFixtures.withUser { app, token, userId in
                try await makeOld(app, userId)
                var id = UUID()
                try await send(app, .GET, "v1/recaps/month/\(lastMonthKey())", token: token) { res in
                    #expect(res.status == .ok)
                    id = try res.content.decode(ResponseProbe.self).id
                }
                try await send(app, .POST, "v1/recaps/\(id)/opened", token: token) { #expect($0.status == .noContent) }
                try await send(app, .POST, "v1/recaps/\(id)/completed", token: token) { #expect($0.status == .noContent) }
                try await send(app, .GET, "v1/recaps", token: token) { res in
                    #expect(res.status == .ok)
                    let list = try res.content.decode(RecapListResponse.self)
                    let row = list.recaps.first { $0.id == id }
                    #expect(row?.openedAt != nil)
                    #expect(row?.completedAt != nil)
                }
            }
        }
    }

    @Test("Another user's recap id is 404")
    func foreignIdIs404() async throws {
        try await withFlags {
            try await RecapFixtures.withUser { app, tokenA, userA in
                try await makeOld(app, userA)
                let other = try await RecapFixtures.registerUser(app: app)
                var id = UUID()
                try await send(app, .GET, "v1/recaps/month/\(lastMonthKey())", token: tokenA) { res in
                    id = try res.content.decode(ResponseProbe.self).id
                }
                try await send(app, .POST, "v1/recaps/\(id)/opened", token: other.token) { #expect($0.status == .notFound) }
                try await send(app, .POST, "v1/recaps/\(id)/completed", token: other.token) { #expect($0.status == .notFound) }
                try await send(app, .POST, "v1/recaps/\(UUID())/opened", token: tokenA) { #expect($0.status == .notFound) }
            }
        }
    }
}
