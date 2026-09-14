import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Retirement projection engine")
struct RetirementProjectionEngineTests {
    private let engine = RetirementProjectionEngine(rules: RetirementRuleRegistry())

    /// Volatility of zero collapses the Monte Carlo to a single deterministic path, which is
    /// what makes these assertions exact rather than statistical.
    private func input(
        currentAge: Int = 40,
        retirementAge: Int = 60,
        longevityAge: Int = 90,
        desiredAnnualSpending: Double = 33600,
        inflationRate: Double = 0.02,
        expectedAnnualReturn: Double = 0,
        currentBalance: Double = 1_000_000,
        withdrawalStrategy: RetirementWithdrawalStrategy = .fixedRealSpending,
        publicPension: RetirementPensionIncome? = nil
    ) -> RetirementPlanInput {
        RetirementPlanInput(
            jurisdiction: .portugal,
            currency: "EUR",
            currentAge: currentAge,
            retirementAge: retirementAge,
            longevityAge: longevityAge,
            annualSalary: 60000,
            desiredAnnualSpending: desiredAnnualSpending,
            inflationRate: inflationRate,
            expectedAnnualReturn: expectedAnnualReturn,
            annualVolatility: 0,
            withdrawalStrategy: withdrawalStrategy,
            accounts: [
                RetirementAccountPlan(
                    id: UUID().uuidString,
                    name: "Taxable",
                    wrapper: .taxable,
                    currentBalance: currentBalance,
                    employeeAnnualContribution: 0
                ),
            ],
            publicPension: publicPension
        )
    }

    private func request() -> RetirementProjectionRequest {
        RetirementProjectionRequest(pathCount: 100, seed: 7)
    }

    /// Regression. Desired spending is entered in today's money, but the engine used to leave
    /// it frozen through the whole accumulation phase and only start inflating it after
    /// retirement. Someone entering 2800 a month and retiring in twenty years had withdrawals
    /// begin at 33.6k instead of 49.9k - the need understated by about a third at 2%.
    @Test
    func `spending is carried forward by inflation across the accumulation years`() throws {
        let projection = try engine.project(portfolioId: UUID(), input: input(), request: request())
        let atRetirement = try #require(projection.points.first { $0.age == 60 })

        let expected: Double = 33600 * pow(1.02, 20)
        #expect(abs(atRetirement.annualWithdrawal - expected) < 0.01)
        #expect(abs(atRetirement.annualWithdrawal - 33600) > 10000)
    }

    /// Regression. The reported withdrawal was read straight off the un-inflated input, so the
    /// chart drew a flat line while the simulation behind it spent an ever-growing amount.
    @Test
    func `the reported withdrawal matches the amount the simulation actually spends`() throws {
        let projection = try engine.project(portfolioId: UUID(), input: input(), request: request())
        let retirementPoints = projection.points.filter { $0.phase == .retirement }

        let withdrawals = retirementPoints.map(\.annualWithdrawal)
        #expect(zip(withdrawals, withdrawals.dropFirst()).allSatisfy { $0 < $1 })

        let first = try #require(retirementPoints.first)
        let second = try #require(retirementPoints.dropFirst().first)
        #expect(abs(second.annualWithdrawal / first.annualWithdrawal - 1.02) < 0.000_001)
    }

    @Test
    func `the balance falls by exactly the inflated withdrawal when returns are flat`() throws {
        let projection = try engine.project(
            portfolioId: UUID(),
            input: input(longevityAge: 62, currentBalance: 1_000_000),
            request: request()
        )

        let atRetirement = try #require(projection.points.first { $0.age == 60 })
        let expectedSpend: Double = 33600 * pow(1.02, 20)

        #expect(abs(atRetirement.p50 - (1_000_000 - expectedSpend)) < 0.01)
    }

    @Test
    func `pension income offsets what has to come out of the portfolio`() throws {
        let pension = RetirementPensionIncome(
            annualAmount: 12000,
            startAge: 60,
            annualIndexationRate: 0,
            currency: "EUR"
        )

        let without = try engine.project(
            portfolioId: UUID(),
            input: input(longevityAge: 62),
            request: request()
        )
        let with = try engine.project(
            portfolioId: UUID(),
            input: input(longevityAge: 62, publicPension: pension),
            request: request()
        )

        let withoutAt60 = try #require(without.points.first { $0.age == 60 })
        let withAt60 = try #require(with.points.first { $0.age == 60 })

        #expect(withAt60.p50 > withoutAt60.p50)
        #expect(abs((withAt60.p50 - withoutAt60.p50) - 12000) < 0.01)
    }

    @Test
    func `a portfolio that cannot fund the plan reports a shortfall age`() throws {
        let projection = try engine.project(
            portfolioId: UUID(),
            input: input(currentBalance: 150_000),
            request: request()
        )

        #expect(projection.summary.shortfallAge != nil)
        #expect(projection.summary.readinessProbability < 1)
    }

    @Test
    func `a portfolio that comfortably funds the plan is judged ready`() throws {
        let projection = try engine.project(
            portfolioId: UUID(),
            input: input(currentBalance: 5_000_000),
            request: request()
        )

        #expect(projection.summary.shortfallAge == nil)
        #expect(projection.summary.readinessProbability == 1)
    }

    @Test
    func `an unusably short horizon is rejected`() {
        #expect(throws: (any Error).self) {
            try engine.project(
                portfolioId: UUID(),
                input: input(currentAge: 60, retirementAge: 50),
                request: request()
            )
        }
    }
}
