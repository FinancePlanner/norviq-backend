import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

@Suite("Planning controller", .serialized)
struct PlanningControllerTests {
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

    private func plan() -> ProjectionAssumptions {
        ProjectionAssumptions(initialAmount: 10000, monthlyContribution: 400,
                              annualReturnRate: 0.07, years: 20)
    }

    private func need() -> RetirementNeedInput {
        RetirementNeedInput(currentAge: 40, retirementAge: 60, longevityAge: 90,
                            monthlyCostOfLifeToday: 2800, expectedAnnualReturn: 0.07)
    }

    @Test("Unauthenticated callers cannot reach the planning routes")
    func unauthenticatedIsRejected() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/planning/prefill") { response async throws in
                #expect(response.status == .unauthorized)
            }
        }
    }

    /// The headline end-to-end case from the brief: what does 10,000 plus 400 a
    /// month become over twenty years at 7%.
    @Test("A projection answers with a value, a year table and its assumptions")
    func projectionRoundTrip() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "grow@example.com", username: "grow_user")

            try await app.testing().test(.POST, "v1/planning/projection", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(GrowthProjectionRequest(assumptions: plan()))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(GrowthProjectionResponse.self)

                // Hand-checked: 10,000 x 1.07^20 plus 400 a month as an ordinary
                // annuity at the same effective rate.
                #expect(abs(body.result.endingValueNominal - 241_710) < 500)
                #expect(body.result.years.count == 21)
                #expect(body.result.endingValueReal < body.result.endingValueNominal)
                #expect(body.sensitivity.count == 3)
                #expect(body.assumptionNotes.isEmpty == false)
            })
        }
    }

    @Test("A nonsense horizon is refused with a readable reason")
    func projectionValidation() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "bad@example.com", username: "bad_user")
            let assumptions = ProjectionAssumptions(initialAmount: 1, monthlyContribution: 1,
                                                    annualReturnRate: 0.07, years: 500)

            try await app.testing().test(.POST, "v1/planning/projection", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(GrowthProjectionRequest(assumptions: assumptions))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    /// The product line. A gap on its own is forgettable; the response has to say
    /// what to do about it.
    @Test("A retirement plan answers with a gap and the lever that closes it")
    func retirementReturnsALever() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "retire@example.com", username: "retire_user")

            try await app.testing().test(.POST, "v1/planning/retirement", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(RetirementPlanningRequest(need: need(), plan: plan()))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(RetirementPlanningResponse.self)

                #expect(body.need.nestEggAtWithdrawalRate > 0)
                #expect(body.need.depletion.isEmpty == false)
                #expect(body.lever.gap > 0)
                #expect(body.lever.additionalMonthlyContribution != nil)
                #expect(body.readinessProbability != nil)
                #expect(body.assumptionNotes.isEmpty == false)
            })
        }
    }

    @Test("The readiness probability can be skipped when it is not wanted")
    func retirementWithoutProbability() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "quick@example.com", username: "quick_user")
            let request = RetirementPlanningRequest(need: need(), plan: plan(), includeProbability: false)

            try await app.testing().test(.POST, "v1/planning/retirement", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(request)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(RetirementPlanningResponse.self)
                #expect(body.readinessProbability == nil)
                #expect(body.lever.gap > 0)
            })
        }
    }

    /// A user with no budget and no portfolio must get "unknown", not zero. A cost
    /// of life of nothing would project a retirement that costs nothing.
    @Test("Pre-fill reports what is unknown rather than guessing zero")
    func prefillOnAnEmptyAccount() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "empty@example.com", username: "empty_user")

            try await app.testing().test(.GET, "v1/planning/prefill", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(PlanningPrefill.self)
                #expect(body.monthlyCostOfLife == nil)
                #expect(body.hasBudget == false)
                #expect(body.hasPortfolio == false)
                #expect(body.portfolioValue == 0)
            })
        }
    }

    @Test("Scenarios round-trip through create, list and delete")
    func scenarioRoundTrip() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "scenarios@example.com", username: "scenario_user")
            let upsert = PlanningScenarioUpsertRequest(
                name: "Lean FIRE",
                kind: .retirement,
                isDefault: true,
                input: PlanningScenarioInput(retirement: need())
            )

            var createdId = ""
            try await app.testing().test(.POST, "v1/planning/scenarios", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(upsert)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let body = try res.content.decode(PlanningScenario.self)
                #expect(body.name == "Lean FIRE")
                #expect(body.isDefault)
                #expect(body.input.retirement != nil)
                createdId = body.id
            })

            try await app.testing().test(.GET, "v1/planning/scenarios", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([PlanningScenario].self)
                #expect(body.count == 1)
            })

            try await app.testing().test(.DELETE, "v1/planning/scenarios/\(createdId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            try await app.testing().test(.GET, "v1/planning/scenarios", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                let body = try res.content.decode([PlanningScenario].self)
                #expect(body.isEmpty)
            })
        }
    }

    @Test("Two scenarios cannot share a name")
    func duplicateScenarioNameIsRejected() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "dupe@example.com", username: "dupe_user")
            let upsert = PlanningScenarioUpsertRequest(
                name: "Base", kind: .growth, input: PlanningScenarioInput(growth: plan())
            )

            try await app.testing().test(.POST, "v1/planning/scenarios", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(upsert)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/planning/scenarios", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(upsert)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("A scenario missing the inputs for its kind is refused")
    func scenarioKindMustMatchItsInput() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "mismatch@example.com", username: "mismatch_user")
            let upsert = PlanningScenarioUpsertRequest(
                name: "Wrong shape", kind: .retirement, input: PlanningScenarioInput(growth: plan())
            )

            try await app.testing().test(.POST, "v1/planning/scenarios", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(upsert)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    /// Scenarios are the user's, not the account next door's.
    @Test("One user cannot see or delete another's scenarios")
    func scenariosAreScopedToTheirOwner() async throws {
        try await withApp { app in
            let owner = try await registerUser(on: app, email: "owner@example.com", username: "owner_user")
            let stranger = try await registerUser(on: app, email: "stranger@example.com", username: "stranger_user")

            var createdId = ""
            try await app.testing().test(.POST, "v1/planning/scenarios", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
                try req.content.encode(PlanningScenarioUpsertRequest(
                    name: "Mine", kind: .growth, input: PlanningScenarioInput(growth: plan())
                ))
            }, afterResponse: { res async throws in
                createdId = try res.content.decode(PlanningScenario.self).id
            })

            try await app.testing().test(.GET, "v1/planning/scenarios", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: stranger.token)
            }, afterResponse: { res async throws in
                let body = try res.content.decode([PlanningScenario].self)
                #expect(body.isEmpty)
            })

            try await app.testing().test(.DELETE, "v1/planning/scenarios/\(createdId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: stranger.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }
}
