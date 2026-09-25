import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

@Suite("Onboarding state", .serialized)
struct OnboardingTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
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

    private func registerUser(on app: Application, identifier: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "onboarding_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "onboarding+\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    private func getState(_ app: Application, token: String) async throws -> OnboardingStateDTO {
        var state: OnboardingStateDTO?
        try await app.testing().test(.GET, "v1/onboarding", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            state = try res.content.decode(OnboardingStateDTO.self)
        })
        return try #require(state)
    }

    /// Sends a raw JSON body so tests can send keys the DTO does not have.
    private func patch(_ app: Application, token: String, json: String) async throws -> (HTTPStatus, OnboardingStateDTO?) {
        var status: HTTPStatus = .internalServerError
        var state: OnboardingStateDTO?
        try await app.testing().test(.PATCH, "v1/onboarding", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: json)
        }, afterResponse: { res async throws in
            status = res.status
            if res.status == .ok {
                state = try res.content.decode(OnboardingStateDTO.self)
            }
        })
        return (status, state)
    }

    @Test("A new account starts with nothing done and no funnel position")
    func freshAccount() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "fresh")
            let state = try await getState(app, token: auth.token)
            #expect(state == OnboardingStateDTO())
        }
    }

    @Test("Unauthenticated reads are rejected")
    func unauthenticated() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/onboarding", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Funnel step is stored and returned")
    func funnelStep() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "step")
            let (status, state) = try await patch(app, token: auth.token, json: #"{"funnelStep":"budget"}"#)
            #expect(status == .ok)
            #expect(state?.funnelStep == "budget")
            #expect(try await getState(app, token: auth.token).funnelStep == "budget")
        }
    }

    @Test("Unknown funnel steps are rejected")
    func unknownStep() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "badstep")
            let (status, _) = try await patch(app, token: auth.token, json: #"{"funnelStep":"nirvana"}"#)
            #expect(status == .badRequest)
        }
    }

    @Test("Funnel completion is one-way and keeps its first timestamp")
    func funnelCompletionIsOneWayAndIdempotent() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "done")
            let (_, first) = try await patch(app, token: auth.token, json: #"{"funnelCompleted":true}"#)
            let firstAt = try #require(first?.funnelCompletedAt)
            let (_, second) = try await patch(app, token: auth.token, json: #"{"funnelCompleted":true}"#)
            #expect(second?.funnelCompletedAt == firstAt)
            let (status, _) = try await patch(app, token: auth.token, json: #"{"funnelCompleted":false}"#)
            #expect(status == .badRequest)
        }
    }

    @Test("Clients cannot write guided latches", arguments: [
        #"{"addHoldingCompleted":true}"#,
        #"{"firstHoldingAt":"2026-09-24T10:00:00Z"}"#,
        #"{"set_budget_completed":true}"#,
        #"{"funnelStep":"budget","setGoalCompleted":true}"#,
    ])
    func latchesAreServerOwned(_ json: String) async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "latch\(abs(json.hashValue) % 10000)")
            let (status, _) = try await patch(app, token: auth.token, json: json)
            #expect(status == .badRequest)
            #expect(try await getState(app, token: auth.token) == OnboardingStateDTO())
        }
    }

    @Test("Dismissal is two-way")
    func dismissal() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "dismiss")
            let (_, hidden) = try await patch(app, token: auth.token, json: #"{"guidedStartDismissed":true}"#)
            #expect(hidden?.guidedStartDismissedAt != nil)
            let (_, shown) = try await patch(app, token: auth.token, json: #"{"guidedStartDismissed":false}"#)
            #expect(shown?.guidedStartDismissedAt == nil)
        }
    }

    @Test("Backfill finishes the funnel and hides the card for existing accounts only")
    func backfill() async throws {
        try await withApp { app in
            let existing = try await registerUser(on: app, identifier: "legacy")
            let alreadyRead = try await registerUser(on: app, identifier: "hasrow")
            _ = try await getState(app, token: alreadyRead.token) // creates its row first

            let sql = try #require(app.db as? any SQLDatabase)
            try await OnboardingBackfill.run(on: sql)

            let legacy = try await getState(app, token: existing.token)
            #expect(legacy.funnelCompletedAt != nil)
            #expect(legacy.guidedStartDismissedAt != nil)

            let untouched = try await getState(app, token: alreadyRead.token)
            #expect(untouched.funnelCompletedAt == nil)
            #expect(untouched.guidedStartDismissedAt == nil)
        }
    }

    @Test("Backfill does not count crypto toward add_holding")
    func backfillExcludesCrypto() async throws {
        try await withApp { app in
            let cryptoOnly = try await registerUser(on: app, identifier: "cryptoonly")
            let mixed = try await registerUser(on: app, identifier: "mixed")
            for (user, holdings) in [
                (cryptoOnly, [("BTC", AssetCategory.crypto)]),
                (mixed, [("ETH", AssetCategory.crypto), ("AAPL", AssetCategory.stock)]),
            ] {
                let list = PortfolioList(userId: user.userId, name: "Backfill", isDefault: false)
                try await list.save(on: app.db)
                for (symbol, category) in holdings {
                    try await Stock(
                        userId: user.userId, portfolioListId: list.requireID(), symbol: symbol,
                        shares: 1, buyPrice: 100, buyDate: Date(), category: category
                    ).save(on: app.db)
                }
            }

            let sql = try #require(app.db as? any SQLDatabase)
            try await OnboardingBackfill.run(on: sql)

            #expect(try await getState(app, token: cryptoOnly.token).addHoldingCompleted == false)
            #expect(try await getState(app, token: mixed.token).addHoldingCompleted)
        }
    }
}
