import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

/// Goals have always stored annualContributionGrowth and inflationAssumption, and until now
/// no projection read either. These pin that they reach the maths.
@Suite("Goal projection fields", .serialized)
struct GoalProjectionFieldsTests {
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

    private func registerUser(on app: Application, email: String, username: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: username,
            password: "Password123!",
            confirmPassword: "Password123!",
            email: email,
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

    /// Goals refuse to be created without a portfolio, so seed one directly the way the
    /// other suites do rather than going through the portfolio endpoints.
    ///
    /// Each goal gets its own, because active goal allocations against a single portfolio
    /// cannot exceed 100% and a goal created without an explicit allocation claims all of it.
    @discardableResult
    private func seedPortfolio(on app: Application, userId: UUID, name: String) async throws -> UUID {
        let portfolio = PortfolioList(userId: userId, name: name, isDefault: false)
        try await portfolio.save(on: app.db)
        return try portfolio.requireID()
    }

    private func targetDate(yearsFromNow years: Int) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(byAdding: .year, value: years, to: Date()) ?? Date()
        return ISO8601DateFormatter().string(from: date).prefix(10).description
    }

    private func makeGoal(
        on app: Application,
        token: String,
        name: String,
        portfolioId: UUID,
        contributionGrowth: Double,
        inflation: Double
    ) async throws -> FinancialGoal {
        let input = FinancialGoalInput(
            name: name,
            targetAmount: 50000,
            targetDate: targetDate(yearsFromNow: 10),
            baseCurrency: "EUR",
            startingCapital: 10000,
            monthlyContribution: 200,
            annualContributionGrowth: contributionGrowth,
            inflationAssumption: inflation,
            expectedAnnualReturn: 0.06,
            portfolioAllocations: [
                GoalPortfolioAllocation(
                    id: UUID().uuidString,
                    portfolioListId: portfolioId.uuidString,
                    allocationPercentage: 100
                ),
            ]
        )
        var created: FinancialGoal?
        try await app.testing().test(.POST, "v1/financial-goals", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(input)
        }, afterResponse: { res async throws in
            if res.status != .ok, res.status != .created {
                Issue.record("create goal failed: \(res.status) body=\(res.body.string)")
                return
            }
            created = try res.content.decode(FinancialGoal.self)
        })
        return try #require(created)
    }

    private func progress(on app: Application, token: String, goalId: String) async throws -> GoalProgress {
        var result: GoalProgress?
        try await app.testing().test(.GET, "v1/financial-goals/\(goalId)/progress", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            result = try res.content.decode(GoalProgress.self)
        })
        return try #require(result)
    }

    /// The headline regression. Two goals identical but for the contribution growth must no
    /// longer project the same number.
    @Test("Contribution growth raises the projected value")
    func contributionGrowthReachesTheProjection() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "growth@example.com", username: "growth_user")
            let portfolioA = try await seedPortfolio(on: app, userId: auth.userId, name: "Level")
            let portfolioB = try await seedPortfolio(on: app, userId: auth.userId, name: "Growing")

            let level = try await makeGoal(
                on: app, token: auth.token, name: "Level", portfolioId: portfolioA, contributionGrowth: 0, inflation: 0
            )
            let growing = try await makeGoal(
                on: app, token: auth.token, name: "Growing", portfolioId: portfolioB, contributionGrowth: 0.05, inflation: 0
            )

            let levelProgress = try await progress(on: app, token: auth.token, goalId: level.id)
            let growingProgress = try await progress(on: app, token: auth.token, goalId: growing.id)

            #expect(growingProgress.projectedValueAtTarget > levelProgress.projectedValueAtTarget)
        }
    }

    /// A target in today's money is a bigger number by the time it falls due, so the same
    /// plan reaches it later.
    @Test("Inflation pushes the projected completion date out")
    func inflationReachesTheCompletionDate() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "inflation@example.com", username: "inflation_user")
            let portfolioA = try await seedPortfolio(on: app, userId: auth.userId, name: "Nominal")
            let portfolioB = try await seedPortfolio(on: app, userId: auth.userId, name: "Real")

            let nominal = try await makeGoal(
                on: app, token: auth.token, name: "Nominal", portfolioId: portfolioA, contributionGrowth: 0, inflation: 0
            )
            let real = try await makeGoal(
                on: app, token: auth.token, name: "Real", portfolioId: portfolioB, contributionGrowth: 0, inflation: 0.03
            )

            let nominalProgress = try await progress(on: app, token: auth.token, goalId: nominal.id)
            let realProgress = try await progress(on: app, token: auth.token, goalId: real.id)

            let nominalMonths = try #require(nominalProgress.driftMonths)
            let realMonths = try #require(realProgress.driftMonths)

            // Same plan, same target on paper - the inflating one takes longer.
            #expect(realMonths > nominalMonths)
        }
    }

    /// percentComplete compares today's value against the target, and both are in today's
    /// money. Inflating the target there would make progress shrink for no reason.
    @Test("Inflation does not distort how complete a goal looks today")
    func percentCompleteStaysInTodaysMoney() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "percent@example.com", username: "percent_user")
            let portfolioA = try await seedPortfolio(on: app, userId: auth.userId, name: "Nominal")
            let portfolioB = try await seedPortfolio(on: app, userId: auth.userId, name: "Real")

            let nominal = try await makeGoal(
                on: app, token: auth.token, name: "Nominal", portfolioId: portfolioA, contributionGrowth: 0, inflation: 0
            )
            let real = try await makeGoal(
                on: app, token: auth.token, name: "Real", portfolioId: portfolioB, contributionGrowth: 0, inflation: 0.03
            )

            let nominalProgress = try await progress(on: app, token: auth.token, goalId: nominal.id)
            let realProgress = try await progress(on: app, token: auth.token, goalId: real.id)

            #expect(abs(nominalProgress.percentComplete - realProgress.percentComplete) < 0.000_001)
            #expect(nominalProgress.targetAmount == realProgress.targetAmount)
        }
    }
}
