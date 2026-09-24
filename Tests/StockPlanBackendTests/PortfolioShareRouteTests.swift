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

    @Test("Requires auth")
    func requiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/portfolio/share-links/all") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
