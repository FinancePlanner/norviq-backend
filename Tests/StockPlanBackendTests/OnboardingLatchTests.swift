import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

@Suite("Onboarding latches", .serialized)
struct OnboardingLatchTests {
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
            username: "latch_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "latch+\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response)
    }

    private func state(_ app: Application, _ token: String) async throws -> OnboardingStateDTO {
        var state: OnboardingStateDTO?
        try await app.testing().test(.GET, "v1/onboarding", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            state = try res.content.decode(OnboardingStateDTO.self)
        })
        return try #require(state)
    }

    private func addStock(
        _ app: Application, _ token: String, symbol: String = "AAPL", category: AssetCategory = .stock
    ) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(StockRequest(
                symbol: symbol, shares: 1, buyPrice: 100, buyDate: "2026-01-01", notes: nil, category: category
            ))
        }, afterResponse: { res async in
            status = res.status
        })
        return status
    }

    private func createSnapshot(_ app: Application, _ token: String, netSalary: Double) async throws {
        try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(BudgetSnapshotRequest(monthStart: "2026-09-01", netSalary: netSalary, targetShares: [:]))
        }, afterResponse: { res async in
            #expect(res.status == .created)
        })
    }

    @Test("Adding a stock latches add_holding, once")
    func holdingLatch() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "holding")
            #expect(try await addStock(app, auth.token) == .created)
            let first = try await state(app, auth.token)
            #expect(first.addHoldingCompleted)
            #expect(first.funnelStep == nil) // latching created the row without touching the funnel

            _ = try await addStock(app, auth.token, symbol: "MSFT")
            #expect(try await state(app, auth.token).firstHoldingAt == first.firstHoldingAt)
        }
    }

    @Test("A crypto holding does not latch add_holding; an ETF does")
    func cryptoDoesNotLatchHolding() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "crypto")
            #expect(try await addStock(app, auth.token, symbol: "BTC", category: .crypto) == .created)
            #expect(try await state(app, auth.token).addHoldingCompleted == false)

            #expect(try await addStock(app, auth.token, symbol: "VWCE", category: .etf) == .created)
            #expect(try await state(app, auth.token).addHoldingCompleted)
        }
    }

    @Test("A bulk import latches add_holding only when something non-crypto was created")
    func bulkCryptoOnlyDoesNotLatch() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "bulkcrypto")
            func bulk(_ stocks: [StockRequest]) async throws {
                try await app.testing().test(.POST, "v1/stocks/bulk", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: auth.token)
                    try req.content.encode(BulkStockRequest(stocks: stocks))
                }, afterResponse: { res async in
                    #expect(res.status == .ok)
                })
            }
            try await bulk([
                StockRequest(symbol: "BTC", shares: 1, buyPrice: 100, buyDate: "2026-01-01", notes: nil, category: .crypto),
                StockRequest(symbol: "ETH", shares: 1, buyPrice: 100, buyDate: "2026-01-01", notes: nil, category: .crypto),
            ])
            #expect(try await state(app, auth.token).addHoldingCompleted == false)

            try await bulk([
                StockRequest(symbol: "SOL", shares: 1, buyPrice: 100, buyDate: "2026-01-01", notes: nil, category: .crypto),
                StockRequest(symbol: "AAPL", shares: 1, buyPrice: 100, buyDate: "2026-01-01", notes: nil),
            ])
            #expect(try await state(app, auth.token).addHoldingCompleted)
        }
    }

    @Test("A budget with a salary latches set_budget; a zero-salary budget does not")
    func budgetLatch() async throws {
        try await withApp { app in
            let zero = try await registerUser(on: app, identifier: "zerosalary")
            try await createSnapshot(app, zero.token, netSalary: 0)
            #expect(try await state(app, zero.token).setBudgetCompleted == false)

            let paid = try await registerUser(on: app, identifier: "salary")
            try await createSnapshot(app, paid.token, netSalary: 3000)
            #expect(try await state(app, paid.token).setBudgetCompleted)
        }
    }

    @Test("Opening the planner auto-creates a month but does not latch set_budget")
    func rolloverDoesNotLatchBudget() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "rollover")
            try await app.testing().test(.GET, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            #expect(try await state(app, auth.token).setBudgetCompleted == false)
        }
    }

    @Test("Creating a financial goal latches set_goal")
    func goalLatch() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "goal")
            let portfolio = PortfolioList(userId: auth.userId, name: "Goal", isDefault: false)
            try await portfolio.save(on: app.db)
            let input = try FinancialGoalInput(
                name: "House",
                targetAmount: 50000,
                targetDate: "2036-01-01",
                baseCurrency: "EUR",
                startingCapital: 10000,
                monthlyContribution: 200,
                annualContributionGrowth: 0,
                inflationAssumption: 0,
                expectedAnnualReturn: 0.06,
                portfolioAllocations: [
                    GoalPortfolioAllocation(id: UUID().uuidString, portfolioListId: portfolio.requireID().uuidString, allocationPercentage: 100),
                ]
            )
            try await app.testing().test(.POST, "v1/financial-goals", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(input)
            }, afterResponse: { res async in
                #expect(res.status == .ok || res.status == .created)
            })
            #expect(try await state(app, auth.token).setGoalCompleted)
        }
    }

    @Test("A failing latch never fails the user's action")
    func latchFailureNeverFailsTheAction() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "latchfail")
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE onboarding_state").run()
            #expect(try await addStock(app, auth.token) == .created)
        }
    }
}
