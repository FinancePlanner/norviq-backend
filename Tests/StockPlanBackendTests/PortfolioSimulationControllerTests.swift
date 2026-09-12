import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Portfolio simulation controller", .serialized)
struct PortfolioSimulationControllerTests {
    @Test("Unauthenticated callers cannot reach the simulation routes")
    func unauthenticatedIsRejected() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/portfolio/simulations") { response async throws in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("A simulation round-trips through create, list, and detail")
    func createListDetailRoundTrip() async throws {
        try await withApp { app in
            let auth = try await registerUser("roundtrip", on: app)

            let created: PortfolioSimulation = try await request(
                .POST,
                "v1/portfolio/simulations",
                token: auth.token,
                body: upsert(legs: [("AAPL", 4000), ("MSFT", 3500)]),
                as: PortfolioSimulation.self,
                expectedStatus: .created,
                on: app
            )
            #expect(created.legs.count == 2)
            #expect(created.revision == 1)
            // 7500 bp claimed leaves 2500 bp of cash.
            #expect(created.cashBasisPoints == 2500)
            // A slug is withheld until the user explicitly shares.
            #expect(created.shareSlug == nil)
            #expect(created.shareEnabled == false)

            let listed: PortfolioSimulationListResponse = try await get(
                "v1/portfolio/simulations",
                token: auth.token,
                as: PortfolioSimulationListResponse.self,
                on: app
            )
            #expect(listed.items.count == 1)
            #expect(listed.items.first?.id == created.id)

            let detail: PortfolioSimulation = try await get(
                "v1/portfolio/simulations/\(created.id)",
                token: auth.token,
                as: PortfolioSimulation.self,
                on: app
            )
            #expect(detail.id == created.id)
            #expect(detail.legs.map(\.symbol) == ["AAPL", "MSFT"])
        }
    }

    @Test("Tickers are normalised on the way in")
    func symbolsAreNormalised() async throws {
        try await withApp { app in
            let auth = try await registerUser("normalise", on: app)
            let created: PortfolioSimulation = try await request(
                .POST,
                "v1/portfolio/simulations",
                token: auth.token,
                body: upsert(legs: [(" aapl ", 5000)]),
                as: PortfolioSimulation.self,
                expectedStatus: .created,
                on: app
            )
            #expect(created.legs.first?.symbol == "AAPL")
        }
    }

    @Test("Weights totalling more than one hundred percent are rejected")
    func weightsOverOneHundredPercentRejected() async throws {
        try await withApp { app in
            let auth = try await registerUser("overweight", on: app)
            try await app.testing().test(.POST, "v1/portfolio/simulations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(upsert(legs: [("AAPL", 6000), ("MSFT", 5000)]))
            }, afterResponse: { response async throws in
                #expect(response.status == .unprocessableEntity)
            })
        }
    }

    @Test("A duplicated ticker is rejected")
    func duplicateSymbolRejected() async throws {
        try await withApp { app in
            let auth = try await registerUser("duplicate", on: app)
            try await app.testing().test(.POST, "v1/portfolio/simulations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(upsert(legs: [("AAPL", 3000), ("aapl", 3000)]))
            }, afterResponse: { response async throws in
                #expect(response.status == .unprocessableEntity)
            })
        }
    }

    @Test("A stale expected revision conflicts instead of overwriting")
    func staleRevisionConflicts() async throws {
        try await withApp { app in
            let auth = try await registerUser("stale", on: app)
            let created: PortfolioSimulation = try await request(
                .POST,
                "v1/portfolio/simulations",
                token: auth.token,
                body: upsert(legs: [("AAPL", 5000)]),
                as: PortfolioSimulation.self,
                expectedStatus: .created,
                on: app
            )

            let updated: PortfolioSimulation = try await request(
                .PUT,
                "v1/portfolio/simulations/\(created.id)",
                token: auth.token,
                body: upsert(legs: [("AAPL", 6000)], expectedRevision: created.revision),
                as: PortfolioSimulation.self,
                on: app
            )
            #expect(updated.revision == created.revision + 1)

            // Replaying the first revision must not silently clobber the newer one.
            try await app.testing().test(.PUT, "v1/portfolio/simulations/\(created.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(upsert(legs: [("MSFT", 9000)], expectedRevision: created.revision))
            }, afterResponse: { response async throws in
                #expect(response.status == .conflict)
            })
        }
    }

    @Test("One user cannot read or delete another user's simulation")
    func simulationsAreScopedToTheirOwner() async throws {
        try await withApp { app in
            let owner = try await registerUser("owner", on: app)
            let stranger = try await registerUser("stranger", on: app)

            let created: PortfolioSimulation = try await request(
                .POST,
                "v1/portfolio/simulations",
                token: owner.token,
                body: upsert(legs: [("AAPL", 5000)]),
                as: PortfolioSimulation.self,
                expectedStatus: .created,
                on: app
            )

            // Not found rather than forbidden, so the route cannot confirm the id exists.
            try await app.testing().test(.GET, "v1/portfolio/simulations/\(created.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: stranger.token)
            }, afterResponse: { response async throws in
                #expect(response.status == .notFound)
            })

            try await app.testing().test(.DELETE, "v1/portfolio/simulations/\(created.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: stranger.token)
            }, afterResponse: { response async throws in
                #expect(response.status == .notFound)
            })

            // The owner's copy survived the stranger's delete attempt.
            try await app.testing().test(.GET, "v1/portfolio/simulations/\(created.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
            })
        }
    }

    @Test("Deleting a simulation removes it")
    func deleteRemovesTheSimulation() async throws {
        try await withApp { app in
            let auth = try await registerUser("delete", on: app)
            let created: PortfolioSimulation = try await request(
                .POST,
                "v1/portfolio/simulations",
                token: auth.token,
                body: upsert(legs: [("AAPL", 5000)]),
                as: PortfolioSimulation.self,
                expectedStatus: .created,
                on: app
            )

            try await app.testing().test(.DELETE, "v1/portfolio/simulations/\(created.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { response async throws in
                #expect(response.status == .noContent)
            })

            try await app.testing().test(.GET, "v1/portfolio/simulations/\(created.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { response async throws in
                #expect(response.status == .notFound)
            })
        }
    }

    @Test("Deleting a simulation cascades to its legs")
    func deleteCascadesToLegs() async throws {
        try await withApp { app in
            let auth = try await registerUser("cascade", on: app)
            let created: PortfolioSimulation = try await request(
                .POST,
                "v1/portfolio/simulations",
                token: auth.token,
                body: upsert(legs: [("AAPL", 3000), ("MSFT", 3000)]),
                as: PortfolioSimulation.self,
                expectedStatus: .created,
                on: app
            )
            let id = try #require(UUID(uuidString: created.id))

            try await app.testing().test(.DELETE, "v1/portfolio/simulations/\(created.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { response async throws in
                #expect(response.status == .noContent)
            })

            let orphans = try await PortfolioSimulationLegRecord.query(on: app.db)
                .filter(\.$simulationId == id)
                .count()
            #expect(orphans == 0)
        }
    }

    @Test("Computing a simulation whose targets cannot be priced fails as unprocessable")
    func unpriceableTargetsFailCleanly() async throws {
        try await withApp { app in
            let auth = try await registerUser("unpriced", on: app)
            let created: PortfolioSimulation = try await request(
                .POST,
                "v1/portfolio/simulations",
                token: auth.token,
                body: upsert(legs: [("NOSUCHTICKER", 5000)]),
                as: PortfolioSimulation.self,
                expectedStatus: .created,
                on: app
            )

            // The market data provider is disabled under test, so nothing prices. The point
            // is that this surfaces as a 422 naming the symbol rather than an engine 500.
            try await app.testing().test(
                .POST,
                "v1/portfolio/simulations/\(created.id)/compute",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: auth.token)
                    try req.content.encode(PortfolioSimulationComputeRequest())
                },
                afterResponse: { response async throws in
                    #expect(response.status == .unprocessableEntity)
                    #expect(response.body.string.contains("NOSUCHTICKER"))
                }
            )
        }
    }

    @Test("Cloning requires a source portfolio the caller can actually read")
    func cloningRequiresReadableSourcePortfolio() async throws {
        try await withApp { app in
            let owner = try await registerUser("clone_owner", on: app)
            let stranger = try await registerUser("clone_stranger", on: app)
            let portfolio = PortfolioList(userId: owner.userId, name: "Real", isDefault: true)
            try await portfolio.save(on: app.db)
            let portfolioId = try #require(portfolio.id)

            var payload = upsert(legs: [("AAPL", 5000)])
            payload = PortfolioSimulationUpsertRequest(
                name: payload.name,
                mode: .cloneCurrentPortfolio,
                sourcePortfolioId: portfolioId.uuidString,
                baseCurrency: payload.baseCurrency,
                targetCapital: payload.targetCapital,
                legs: payload.legs
            )

            try await app.testing().test(.POST, "v1/portfolio/simulations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: stranger.token)
                try req.content.encode(payload)
            }, afterResponse: { response async throws in
                #expect(response.status == .notFound)
            })

            try await app.testing().test(.POST, "v1/portfolio/simulations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
                try req.content.encode(payload)
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
            })
        }
    }

    // MARK: - Helpers

    private func upsert(
        legs: [(String, Int)],
        expectedRevision: Int? = nil
    ) -> PortfolioSimulationUpsertRequest {
        PortfolioSimulationUpsertRequest(
            name: "Simulation",
            mode: .fromScratch,
            baseCurrency: "USD",
            targetCapital: 10000,
            legs: legs.map { PortfolioSimulationLegInput(symbol: $0.0, targetBasisPoints: $0.1) },
            expectedRevision: expectedRevision
        )
    }

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
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

    private func registerUser(_ suffix: String, on app: Application) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "simulation_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "simulation+\(suffix)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var auth: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { response async throws in
            #expect(response.status == .ok)
            auth = try response.content.decode(AuthResponse.self)
        })
        return try #require(auth)
    }

    private func request<Response: Content>(
        _ method: HTTPMethod,
        _ path: String,
        token: String,
        body: some Content,
        as _: Response.Type,
        expectedStatus: HTTPStatus = .ok,
        on app: Application
    ) async throws -> Response {
        var decoded: Response?
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(body)
        }, afterResponse: { response async throws in
            #expect(response.status == expectedStatus)
            decoded = try response.content.decode(Response.self)
        })
        return try #require(decoded)
    }

    private func get<Response: Content>(
        _ path: String,
        token: String,
        as _: Response.Type,
        on app: Application
    ) async throws -> Response {
        var decoded: Response?
        try await app.testing().test(path.isEmpty ? .GET : .GET, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { response async throws in
            #expect(response.status == .ok)
            decoded = try response.content.decode(Response.self)
        })
        return try #require(decoded)
    }
}
