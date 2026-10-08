import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Market brief route", .serialized)
struct MarketBriefRouteTests {
    private func registerUser(app: Application) async throws -> UUID {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "brief_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "brief_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        return try await app.jwt.keys.verify(token, as: SessionToken.self).userId
    }

    /// Same as `MCPTokenAuthTests.mintPAT`: the web's PUBLIC_API_TOKEN is a PAT like this.
    private func mintPAT(app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: userId, name: "test", tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue), expiresAt: Date().addingTimeInterval(3600)
        )
        try await pat.save(on: app.db)
        return raw
    }

    private func patWithScopes(_ app: Application, _ scopes: [APIScope]) async throws -> String {
        let user = try await registerUser(app: app)
        return try await mintPAT(app: app, userId: user, scopes: scopes)
    }

    private func get(
        _ app: Application, _ path: String, token: String?,
        _ check: @escaping (TestingHTTPResponse) async throws -> Void
    ) async throws {
        try await app.testing().test(.GET, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = BearerAuthorization(token: token) }
        }, afterResponse: check)
    }

    private func seed(_ app: Application) async throws {
        let repo = app.marketBriefRepository
        let morning = Date(timeIntervalSince1970: 1_791_500_000)
        try await repo.save(
            MarketBriefLanguage.allCases.map { MarketBriefFixtures.response(slot: .morning, language: $0.rawValue) },
            model: "m", generatedAt: morning, on: app.db
        )
        try await repo.save(
            MarketBriefLanguage.allCases.map { MarketBriefFixtures.response(slot: .evening, language: $0.rawValue) },
            model: "m", generatedAt: morning.addingTimeInterval(14 * 3600), on: app.db
        )
    }

    @Test("No token is 401; a PAT without market:read is 403")
    func authMatrix() async throws {
        try await MarketBriefFixtures.withApp { app in
            let wrongScope = try await patWithScopes(app, [.expensesRead])
            try await get(app, "v1/market/brief", token: nil) { #expect($0.status == .unauthorized) }
            try await get(app, "v1/market/brief", token: wrongScope) { #expect($0.status == .forbidden) }
        }
    }

    @Test("Flag off: 200 with enabled false")
    func disabled() async throws {
        try await MarketBriefFixtures.withApp { app in
            let pat = try await patWithScopes(app, [.marketRead])
            try await get(app, "v1/market/brief?lang=pt-PT", token: pat) { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(MarketBriefResponse.self)
                #expect(body.enabled == false)
                #expect(body.language == "pt-PT")
            }
        }
    }

    @Test("Flag on, nothing generated: enabled with no brief")
    func enabledEmpty() async throws {
        try await MarketBriefFixtures.withApp { app in
            app.marketBriefEnabled = true
            let pat = try await patWithScopes(app, [.marketRead])
            try await get(app, "v1/market/brief", token: pat) { res in
                let body = try res.content.decode(MarketBriefResponse.self)
                #expect(body.enabled)
                #expect(body.tradingDate == nil)
            }
        }
    }

    @Test("Latest brief per language, unknown language falls back to en, private cache header")
    func latest() async throws {
        try await MarketBriefFixtures.withApp { app in
            app.marketBriefEnabled = true
            try await seed(app)
            let pat = try await patWithScopes(app, [.marketRead])
            try await get(app, "v1/market/brief?lang=pt", token: pat) { res in
                #expect(res.headers.first(name: .cacheControl) == "private, max-age=300")
                let body = try res.content.decode(MarketBriefResponse.self)
                #expect(body.slot == .evening)
                #expect(body.language == "pt-PT")
            }
            try await get(app, "v1/market/brief?lang=de", token: pat) { res in
                let body = try res.content.decode(MarketBriefResponse.self)
                #expect(body.language == "en")
            }
        }
    }

    @Test("Exact slot and date: found, 404 when missing, 400 on a bad slot or date")
    func exact() async throws {
        try await MarketBriefFixtures.withApp { app in
            app.marketBriefEnabled = true
            try await seed(app)
            let pat = try await patWithScopes(app, [.marketRead])
            try await get(app, "v1/market/brief?slot=morning&date=2026-10-08", token: pat) { res in
                let body = try res.content.decode(MarketBriefResponse.self)
                #expect(body.slot == .morning)
            }
            try await get(app, "v1/market/brief?slot=morning&date=2026-10-09", token: pat) { #expect($0.status == .notFound) }
            try await get(app, "v1/market/brief?slot=noon&date=2026-10-08", token: pat) { #expect($0.status == .badRequest) }
            try await get(app, "v1/market/brief?slot=morning&date=08-10-2026", token: pat) { #expect($0.status == .badRequest) }
        }
    }
}
