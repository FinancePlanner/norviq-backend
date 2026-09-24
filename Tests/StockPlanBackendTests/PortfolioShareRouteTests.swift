import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Share-link lifecycle against a real database: ownership, idempotency,
/// revocation, and what the unauthenticated endpoint is allowed to reveal.
@Suite("Portfolio share routes", .serialized)
struct PortfolioShareRouteTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SHARE_PORTFOLIO_BASE_URL", "https://norviq.test", 1)
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "share_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "share+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response)
    }

    private func bearer(_ auth: AuthResponse) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: auth.token)
        return headers
    }

    @Test("GET with no link returns link:null")
    func emptyStatus() async throws {
        try await withApp { app in
            let auth = try await register(app, "a")
            try await app.testing().test(.GET, "v1/portfolio/share-links/all", headers: bearer(auth)) { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(PortfolioShareLinkStatusResponse.self).link == nil)
            }
        }
    }

    @Test("POST is idempotent and URL uses base env")
    func createIdempotent() async throws {
        try await withApp { app in
            let auth = try await register(app, "b")
            var first: PortfolioShareLinkResponse?
            try await app.testing().test(.POST, "v1/portfolio/share-links/all", headers: bearer(auth)) { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(PortfolioShareLinkResponse.self)
            }
            let link = try #require(first)
            #expect(link.url == "https://norviq.test/p/\(link.slug)")
            #expect(link.slug.hasPrefix("p") && link.slug.count == 23)
            try await app.testing().test(.POST, "v1/portfolio/share-links/all", headers: bearer(auth)) { res async throws in
                #expect(try res.content.decode(PortfolioShareLinkResponse.self).slug == link.slug)
            }
            try await app.testing().test(.GET, "v1/portfolio/share-links/all", headers: bearer(auth)) { res async throws in
                #expect(try res.content.decode(PortfolioShareLinkStatusResponse.self).link?.slug == link.slug)
            }
        }
    }

    @Test("Revoke then create issues a new slug")
    func revokeThenCreate() async throws {
        try await withApp { app in
            let auth = try await register(app, "c")
            var slugs: [String] = []
            for _ in 0 ..< 2 {
                try await app.testing().test(.POST, "v1/portfolio/share-links/all", headers: bearer(auth)) { res async throws in
                    try slugs.append(res.content.decode(PortfolioShareLinkResponse.self).slug)
                }
                try await app.testing().test(.DELETE, "v1/portfolio/share-links/all", headers: bearer(auth)) { res async in
                    #expect(res.status == .noContent)
                }
            }
            #expect(slugs.count == 2 && slugs[0] != slugs[1])
        }
    }

    @Test("Cannot share another user's portfolio")
    func foreignPortfolio() async throws {
        try await withApp { app in
            let owner = try await register(app, "d")
            let other = try await register(app, "e")
            let listId = try await ensureDefaultPortfolioListId(userId: owner.userId, on: app.db)
            try await app.testing().test(.POST, "v1/portfolio/share-links/\(listId.uuidString)", headers: bearer(other)) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    private func seedHolding(_ app: Application, _ auth: AuthResponse, symbol: String, shares: Double, price: Double) async throws {
        let listId = try await ensureDefaultPortfolioListId(userId: auth.userId, on: app.db)
        try await Stock(userId: auth.userId, portfolioListId: listId, symbol: symbol, shares: shares, buyPrice: price, buyDate: Date())
            .save(on: app.db)
    }

    private func createLink(_ app: Application, _ auth: AuthResponse, scope: String = "all") async throws -> PortfolioShareLinkResponse {
        var link: PortfolioShareLinkResponse?
        try await app.testing().test(.POST, "v1/portfolio/share-links/\(scope)", headers: bearer(auth)) { res async throws in
            link = try res.content.decode(PortfolioShareLinkResponse.self)
        }
        return try #require(link)
    }

    @Test("Public share is unauthenticated, percent-only and cacheable")
    func publicShare() async throws {
        try await withApp { app in
            let auth = try await register(app, "f")
            try await seedHolding(app, auth, symbol: "AAPL", shares: 3, price: 200)
            try await seedHolding(app, auth, symbol: "MSFT", shares: 1, price: 200)
            let link = try await createLink(app, auth)
            try await app.testing().test(.GET, "v1/public/portfolio-shares/\(link.slug)") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == "public, max-age=60")
                let body = res.body.string
                #expect(!body.contains("600") && !body.contains("200") && !body.contains("share_f"))
                let dto = try res.content.decode(PublicPortfolioShareResponse.self)
                #expect(dto.holdings.map(\.symbol) == ["AAPL", "MSFT"])
                #expect(dto.holdings.map(\.weightPercent) == [75, 25])
            }
        }
    }

    @Test("Revoked and unknown slugs 404")
    func revokedAndUnknown() async throws {
        try await withApp { app in
            let auth = try await register(app, "g")
            let link = try await createLink(app, auth)
            try await app.testing().test(.DELETE, "v1/portfolio/share-links/all", headers: bearer(auth)) { _ async in }
            for slug in [link.slug, "pdoesnotexist0000000000"] {
                try await app.testing().test(.GET, "v1/public/portfolio-shares/\(slug)") { res async in
                    #expect(res.status == .notFound)
                }
            }
        }
    }

    @Test("A link to a portfolio its creator no longer owns 404s")
    func lostOwnership() async throws {
        try await withApp { app in
            let auth = try await register(app, "h")
            let listId = try await ensureDefaultPortfolioListId(userId: auth.userId, on: app.db)
            let link = try await createLink(app, auth, scope: listId.uuidString)
            // Re-point the link at someone else's portfolio: the public read
            // must re-check ownership rather than trust the stored row.
            let stranger = try await register(app, "i")
            try await seedHolding(app, stranger, symbol: "NVDA", shares: 1, price: 100)
            let row = try #require(try await PortfolioShareLink.query(on: app.db).filter(\.$slug == link.slug).first())
            row.portfolioListId = try await ensureDefaultPortfolioListId(userId: stranger.userId, on: app.db)
            try await row.save(on: app.db)
            try await app.testing().test(.GET, "v1/public/portfolio-shares/\(link.slug)") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Revoke clears every active link for the scope, not just the newest")
    func revokeClearsDuplicates() async throws {
        try await withApp { app in
            let auth = try await register(app, "k")
            let first = try await createLink(app, auth)
            // A lost race between two clients can leave a second active row.
            try await PortfolioShareLink(userId: auth.userId, portfolioListId: nil, slug: "pduplicate0000000000000").save(on: app.db)
            try await app.testing().test(.DELETE, "v1/portfolio/share-links/all", headers: bearer(auth)) { res async in
                #expect(res.status == .noContent)
            }
            for slug in [first.slug, "pduplicate0000000000000"] {
                try await app.testing().test(.GET, "v1/public/portfolio-shares/\(slug)") { res async in
                    #expect(res.status == .notFound, "\(slug) still live")
                }
            }
        }
    }

    @Test("Listing returns every active link across scopes so any client can revoke it")
    func listAcrossScopes() async throws {
        try await withApp { app in
            let auth = try await register(app, "l")
            let listId = try await ensureDefaultPortfolioListId(userId: auth.userId, on: app.db)
            let all = try await createLink(app, auth)
            let one = try await createLink(app, auth, scope: listId.uuidString)
            let other = try await register(app, "m")
            _ = try await createLink(app, other)
            try await app.testing().test(.GET, "v1/portfolio/share-links", headers: bearer(auth)) { res async throws in
                #expect(res.status == .ok)
                let links = try res.content.decode([PortfolioShareLinkResponse].self)
                #expect(Set(links.map(\.slug)) == [all.slug, one.slug])
                #expect(Set(links.map(\.scope)) == ["all", listId.uuidString])
            }
        }
    }

    @Test("Requires auth")
    func requiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/portfolio/share-links/all") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
