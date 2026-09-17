import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor
import VaporTesting

/// What the three ownership routes reject, and how they are registered.
///
/// The service suite covers what happens after the handler delegates; this one
/// covers the part that never reaches the service.
@Suite("Market ownership routes", .serialized)
struct MarketOwnershipRouteTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
                try await app.asyncShutdown()
            } catch {
                try? await app.autoRevert()
                try? await app.asyncShutdown()
                throw error
            }
        }
    }

    private func registerUser(app: Application) async throws -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "own_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "own_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        return token
    }

    // MARK: - Registration order

    @Test("`congress/recent` is registered before `congress/:symbol`")
    func recentIsRegisteredBeforeTheParameterRoute() async throws {
        try await withApp { app in
            let paths = app.routes.all
                .filter { $0.method == .GET }
                .map { $0.path.map(\.description).joined(separator: "/") }

            let recent = try #require(paths.firstIndex(of: "v1/market/congress/recent"))
            let parameterised = try #require(paths.firstIndex(of: "v1/market/congress/:symbol"))

            // Order matters: registered the other way round, a request for
            // /congress/recent would be routed to the symbol handler and asked
            // upstream for a ticker called RECENT.
            #expect(recent < parameterised)
        }
    }

    @Test("All four ownership routes are registered under the market group")
    func allFourRoutesAreRegistered() async throws {
        try await withApp { app in
            let paths = Set(
                app.routes.all
                    .filter { $0.method == .GET }
                    .map { $0.path.map(\.description).joined(separator: "/") }
            )

            #expect(paths.contains("v1/market/insider/:symbol"))
            #expect(paths.contains("v1/market/congress/recent"))
            #expect(paths.contains("v1/market/congress/:symbol"))
            #expect(paths.contains("v1/market/institutional/:symbol"))
        }
    }

    // MARK: - Query validation

    @Test(
        "`days` outside 30…1825 is refused before any upstream call",
        arguments: ["0", "29", "1826", "100000", "-5"]
    )
    func daysOutsideTheRangeIsRefused(days: String) async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)

            try await app.testing().test(.GET, "v1/market/insider/AAPL?days=\(days)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("A `days` inside the range gets past validation")
    func daysInsideTheRangeIsAccepted() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)

            // No FMP provider is configured in the test app, so the handler
            // answers 503 — which it can only do after validation, auth, the
            // scope check and routing have all passed. The claim here is
            // "not rejected", so the assertion is exactly that.
            try await app.testing().test(.GET, "v1/market/insider/AAPL?days=30", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status != .badRequest)
            })
        }
    }

    @Test(
        "`limit` outside 1…200 is refused before any upstream call",
        arguments: ["0", "201", "5000", "-1"]
    )
    func limitOutsideTheRangeIsRefused(limit: String) async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)

            try await app.testing().test(
                .GET, "v1/market/congress/recent?limit=\(limit)", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                }, afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )
        }
    }

    @Test("A `limit` inside the range gets past validation")
    func limitInsideTheRangeIsAccepted() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)

            try await app.testing().test(
                .GET, "v1/market/congress/recent?limit=200", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                }, afterResponse: { res async throws in
                    #expect(res.status != .badRequest)
                }
            )
        }
    }

    @Test("The ownership routes need a session, like every other market route")
    func theRoutesRequireASession() async throws {
        try await withApp { app in
            for path in [
                "v1/market/insider/AAPL",
                "v1/market/congress/AAPL",
                "v1/market/congress/recent",
                "v1/market/institutional/AAPL",
            ] {
                try await app.testing().test(.GET, path, afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                })
            }
        }
    }
}
