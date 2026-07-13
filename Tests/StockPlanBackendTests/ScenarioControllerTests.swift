import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor
import VaporTesting

@Suite("Scenario controller", .serialized)
struct ScenarioControllerTests {
    private struct GoalRequest: Content {
        let portfolioListId: UUID
        let name: String
        let targetAmount: Double
        let targetDate: Date
        let baseCurrency: String
        let monthlyContribution: Double
        let annualContributionGrowth: Double
        let inflationAssumption: Double
    }

    private struct SnapshotRequest: Content {
        let portfolioListId: UUID
        let baseCurrency: String
        let valuationTimestamp: Date
        let payload: ScenarioJSON
        let warnings: ScenarioJSON
    }

    private struct ScenarioRequest: Content {
        let portfolioListId: UUID
        let financialGoalId: UUID?
        let name: String
        let kind: String
        let configuration: ScenarioJSON
        let isSaved: Bool
    }

    private struct RunRequest: Content {
        let snapshotId: UUID
        let seed: UInt64
    }

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let previousFlag = getenv("SCENARIO_PLANNING_ENABLED").map { String(cString: $0) }
            let previousBypass = getenv("BYPASS_BILLING").map { String(cString: $0) }
            setenv("SCENARIO_PLANNING_ENABLED", "true", 1)
            setenv("BYPASS_BILLING", "false", 1)
            defer {
                if let previousFlag {
                    setenv("SCENARIO_PLANNING_ENABLED", previousFlag, 1)
                } else {
                    unsetenv("SCENARIO_PLANNING_ENABLED")
                }
                if let previousBypass {
                    setenv("BYPASS_BILLING", previousBypass, 1)
                } else {
                    unsetenv("BYPASS_BILLING")
                }
            }

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
            username: "scenario_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "scenario+\(suffix)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var auth: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { response async throws in
            #expect(response.status == .ok)
            auth = try response.content.decode(AuthResponse.self)
        })
        let result = try #require(auth)
        let user = try #require(try await User.find(result.userId, on: app.db))
        user.trialStartedAt = nil
        user.trialDays = nil
        user.trialTier = nil
        try await user.save(on: app.db)
        return result
    }

    private func grantPro(_ userId: UUID, on app: Application) async throws {
        try await Entitlement(userId: userId, level: "pro").save(on: app.db)
    }

    private func makePortfolio(for userId: UUID, suffix: String, on app: Application) async throws -> UUID {
        let portfolio = PortfolioList(userId: userId, name: "Scenario \(suffix)", isDefault: true)
        try await portfolio.save(on: app.db)
        return try #require(portfolio.id)
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

    @Test("Scenario routes require Pro access")
    func proGate() async throws {
        try await withApp { app in
            let auth = try await registerUser("free", on: app)
            for path in [
                "v1/financial-goals",
                "v1/scenarios/catalog",
                "v1/portfolio/scenario-snapshots",
                "v1/scenario-runs",
                "v1/holding-risk-profiles",
            ] {
                try await app.testing().test(.GET, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: auth.token)
                }, afterResponse: { response async in
                    #expect(response.status == .forbidden)
                    #expect(response.body.string.contains("scenario_planning"))
                })
            }
        }
    }

    @Test("Goals and immutable snapshots are isolated by owner")
    func ownershipAndSnapshotImmutability() async throws {
        try await withApp { app in
            let owner = try await registerUser("owner", on: app)
            let other = try await registerUser("other", on: app)
            try await grantPro(owner.userId, on: app)
            try await grantPro(other.userId, on: app)
            let portfolioId = try await makePortfolio(for: owner.userId, suffix: "Owner", on: app)

            let goal: FinancialGoalModel = try await request(
                .POST,
                "v1/financial-goals",
                token: owner.token,
                body: GoalRequest(
                    portfolioListId: portfolioId,
                    name: "Retirement corpus",
                    targetAmount: 1_000_000,
                    targetDate: Date().addingTimeInterval(20 * 365 * 86400),
                    baseCurrency: "eur",
                    monthlyContribution: 1500,
                    annualContributionGrowth: 0.03,
                    inflationAssumption: 0.02
                ),
                as: FinancialGoalModel.self,
                on: app
            )
            #expect(goal.baseCurrency == "EUR")

            let payload = ScenarioJSON([
                "totalValue": .number(42000),
                "holdings": .array([.object(["symbol": .string("TEST"), "value": .number(42000)])]),
            ])
            let snapshot: ScenarioSnapshotModel = try await request(
                .POST,
                "v1/portfolio/scenario-snapshots",
                token: owner.token,
                body: SnapshotRequest(
                    portfolioListId: portfolioId,
                    baseCurrency: "eur",
                    valuationTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    payload: payload,
                    warnings: ScenarioJSON(["items": .array([])])
                ),
                as: ScenarioSnapshotModel.self,
                on: app
            )
            let snapshotId = try #require(snapshot.id)

            for path in try ["v1/financial-goals/\(#require(goal.id))", "v1/portfolio/scenario-snapshots/\(snapshotId)"] {
                try await app.testing().test(.GET, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: other.token)
                }, afterResponse: { response async in
                    #expect(response.status == .notFound)
                })
            }

            var fetched: ScenarioSnapshotModel?
            try await app.testing().test(.GET, "v1/portfolio/scenario-snapshots/\(snapshotId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                fetched = try response.content.decode(ScenarioSnapshotModel.self)
            })
            #expect(fetched?.payload == payload)

            try await app.testing().test(.PUT, "v1/portfolio/scenario-snapshots/\(snapshotId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
                try req.content.encode(SnapshotRequest(
                    portfolioListId: portfolioId,
                    baseCurrency: "USD",
                    valuationTimestamp: Date(),
                    payload: ScenarioJSON(["totalValue": .number(0)]),
                    warnings: ScenarioJSON()
                ))
            }, afterResponse: { response async in
                #expect(response.status == .notFound)
            })
        }
    }

    @Test("Queued runs can be cancelled and cannot cross ownership boundaries")
    func runCancellationAndOwnership() async throws {
        try await withApp { app in
            let owner = try await registerUser("runner", on: app)
            let other = try await registerUser("observer", on: app)
            try await grantPro(owner.userId, on: app)
            try await grantPro(other.userId, on: app)
            let portfolioId = try await makePortfolio(for: owner.userId, suffix: "Run", on: app)

            let scenario: ScenarioDefinitionModel = try await request(
                .POST,
                "v1/scenarios",
                token: owner.token,
                body: ScenarioRequest(
                    portfolioListId: portfolioId,
                    financialGoalId: nil,
                    name: "Seeded normal",
                    kind: "monte_carlo",
                    configuration: ScenarioJSON(["distribution": .string("normal"), "paths": .number(10000)]),
                    isSaved: false
                ),
                as: ScenarioDefinitionModel.self,
                on: app
            )
            let snapshot: ScenarioSnapshotModel = try await request(
                .POST,
                "v1/portfolio/scenario-snapshots",
                token: owner.token,
                body: SnapshotRequest(
                    portfolioListId: portfolioId,
                    baseCurrency: "USD",
                    valuationTimestamp: Date(),
                    payload: ScenarioJSON(["totalValue": .number(100_000)]),
                    warnings: ScenarioJSON()
                ),
                as: ScenarioSnapshotModel.self,
                on: app
            )
            let scenarioId = try #require(scenario.id)
            let snapshotId = try #require(snapshot.id)
            let run: ScenarioRunModel = try await request(
                .POST,
                "v1/scenarios/\(scenarioId)/runs",
                token: owner.token,
                body: RunRequest(snapshotId: snapshotId, seed: 7),
                as: ScenarioRunModel.self,
                expectedStatus: .accepted,
                on: app
            )
            let runId = try #require(run.id)
            #expect(run.state == "queued")

            try await app.testing().test(.GET, "v1/scenario-runs/\(runId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: other.token)
            }, afterResponse: { response async in
                #expect(response.status == .notFound)
            })
            try await app.testing().test(.DELETE, "v1/scenario-runs/\(runId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
            }, afterResponse: { response async in
                #expect(response.status == .noContent)
            })
            let cancelled = try #require(try await ScenarioRunModel.find(runId, on: app.db))
            #expect(cancelled.state == "cancelled")
            #expect(cancelled.completedAt != nil)

            try await app.testing().test(.DELETE, "v1/scenario-runs/\(runId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
            }, afterResponse: { response async in
                #expect(response.status == .conflict)
            })
        }
    }

    @Test("Worker applies linked financial goal assumptions")
    func linkedGoalDrivesMonteCarlo() async throws {
        try await withApp { app in
            let auth = try await registerUser("goalworker", on: app)
            try await grantPro(auth.userId, on: app)
            let portfolioId = try await makePortfolio(for: auth.userId, suffix: "Goal", on: app)
            let targetDate = Calendar(identifier: .gregorian).date(byAdding: .month, value: 18, to: Date())!
            let goal: FinancialGoalModel = try await request(
                .POST,
                "v1/financial-goals",
                token: auth.token,
                body: GoalRequest(
                    portfolioListId: portfolioId, name: "Linked goal", targetAmount: 125_000,
                    targetDate: targetDate, baseCurrency: "USD", monthlyContribution: 750,
                    annualContributionGrowth: 0.04, inflationAssumption: 0.025
                ),
                as: FinancialGoalModel.self,
                on: app
            )
            let goalId = try #require(goal.id)
            let scenario: ScenarioDefinitionModel = try await request(
                .POST,
                "v1/scenarios",
                token: auth.token,
                body: ScenarioRequest(
                    portfolioListId: portfolioId, financialGoalId: goalId, name: "Goal simulation",
                    kind: "monte_carlo",
                    configuration: ScenarioJSON([
                        "distribution": .string("normal"), "path_count": .number(200),
                        "horizon_months": .number(360), "annual_return": .number(0.06),
                        "annual_volatility": .number(0.12),
                    ]),
                    isSaved: true
                ),
                as: ScenarioDefinitionModel.self,
                on: app
            )
            let snapshot: ScenarioSnapshotModel = try await request(
                .POST,
                "v1/portfolio/scenario-snapshots",
                token: auth.token,
                body: SnapshotRequest(
                    portfolioListId: portfolioId, baseCurrency: "USD", valuationTimestamp: Date(),
                    payload: ScenarioJSON(["total_value": .number(100_000), "holdings": .array([])]),
                    warnings: ScenarioJSON()
                ),
                as: ScenarioSnapshotModel.self,
                on: app
            )
            let run: ScenarioRunModel = try await request(
                .POST,
                "v1/scenarios/\(#require(scenario.id))/runs",
                token: auth.token,
                body: RunRequest(snapshotId: #require(snapshot.id), seed: 123),
                as: ScenarioRunModel.self,
                expectedStatus: .accepted,
                on: app
            )

            await ScenarioRunWorker(intervalSeconds: 60, maxConcurrent: 1).runOnce(app)
            let completed = try #require(try await ScenarioRunModel.find(#require(run.id), on: app.db))
            #expect(completed.state == "completed")
            let result = try #require(completed.result)
            #expect(result.values["goal_probability"] != .null)
            #expect(result.values["horizon_months"]?.number == 17 || result.values["horizon_months"]?.number == 18)
            let assumptions = try #require(result.values["assumptions"]?.object)
            #expect(assumptions["monthly_contribution"]?.number == 750)
            #expect(assumptions["annual_contribution_growth"]?.number == 0.04)
            #expect(assumptions["inflation"]?.number == 0.025)
            #expect(assumptions["financial_goal_id"]?.string == goalId.uuidString)

            let duplicate: ScenarioRunModel = try await request(
                .POST,
                "v1/scenarios/\(#require(scenario.id))/runs",
                token: auth.token,
                body: RunRequest(snapshotId: #require(snapshot.id), seed: 123),
                as: ScenarioRunModel.self,
                expectedStatus: .ok,
                on: app
            )
            #expect(duplicate.id == run.id)
        }
    }
}
