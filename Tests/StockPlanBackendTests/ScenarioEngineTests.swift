import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Scenario engine")
struct ScenarioEngineTests {
    @Test
    func `holding override replaces broader percentage shocks`() {
        let holding = ScenarioEngineHolding(
            id: "one", value: 100, assetClass: "stock", sector: "technology",
            region: "US", currency: "USD", duration: nil, convexity: nil
        )
        let shocks = ScenarioShockSet(
            holdings: ["one": -0.1], assetClasses: ["stock": -0.2], sectors: ["technology": -0.3]
        )
        #expect(ScenarioEngine().customValue(for: holding, shocks: shocks) == 90)
    }

    @Test
    func `holding override still applies independent bond rate shock`() {
        let holding = ScenarioEngineHolding(
            id: "bond", value: 1000, assetClass: "bond", sector: nil,
            region: nil, currency: "USD", duration: 5, convexity: 20
        )
        let shocks = ScenarioShockSet(
            holdings: ["bond": -0.1], assetClasses: ["bond": -0.5], parallelRateShiftBps: 100
        )
        #expect(abs(ScenarioEngine().customValue(for: holding, shocks: shocks) - 855.9) < 0.0001)
    }

    @Test
    func `applicable broad shocks compound`() {
        let holding = ScenarioEngineHolding(
            id: "one", value: 100, assetClass: "stock", sector: "technology",
            region: "US", currency: "USD", duration: nil, convexity: nil
        )
        let shocks = ScenarioShockSet(assetClasses: ["stock": -0.2], sectors: ["technology": -0.25])
        #expect(abs(ScenarioEngine().customValue(for: holding, shocks: shocks) - 60) < 0.0001)
    }

    @Test
    func `bond rate shock applies duration and convexity`() {
        let bond = ScenarioEngineHolding(
            id: "bond", value: 1000, assetClass: "bond", sector: nil,
            region: nil, currency: "USD", duration: 5, convexity: 20
        )
        let value = ScenarioEngine().customValue(
            for: bond,
            shocks: ScenarioShockSet(parallelRateShiftBps: 100)
        )
        #expect(abs(value - 951) < 0.0001)
    }

    @Test
    func `seeded monte carlo is reproducible`() {
        let engine = ScenarioEngine()
        let first = engine.monteCarloTerminalValues(
            initialValue: 10000, monthlyContribution: 100, annualReturn: 0.07,
            annualVolatility: 0.15, horizonMonths: 120, pathCount: 100, seed: 42
        )
        let second = engine.monteCarloTerminalValues(
            initialValue: 10000, monthlyContribution: 100, annualReturn: 0.07,
            annualVolatility: 0.15, horizonMonths: 120, pathCount: 100, seed: 42
        )
        #expect(first == second)
    }

    @Test
    func `maximum drawdown uses prior peak`() {
        #expect(ScenarioEngine().maximumDrawdown([100, 120, 90, 110]) == 0.25)
    }

    @Test
    func `recovery months finds first recovery after shock`() {
        #expect(ScenarioEngine().recoveryMonths(timelineValues: [100, 80, 90, 100, 110], initialValue: 100) == 3)
        #expect(ScenarioEngine().recoveryMonths(timelineValues: [100, 80, 90], initialValue: 100) == nil)
    }

    @Test
    func `months to goal is finite for funded path`() {
        let months = ScenarioEngine().monthsToGoal(
            initialValue: 100_000,
            monthlyContribution: 500,
            annualReturn: 0.07,
            annualInflation: 0.02,
            annualContributionGrowth: 0,
            targetAmount: 120_000,
            maxMonths: 600
        )
        #expect(months != nil)
        #expect((months ?? 0) > 0)
        #expect((months ?? 999) < 600)
    }

    @Test
    func `required contribution rises after a portfolio shock`() {
        let engine = ScenarioEngine()
        let impact = engine.goalImpact(
            ScenarioGoalImpactInput(
                initialValue: 100_000,
                stressedValue: 70000,
                monthlyContribution: 500,
                annualReturn: 0.07,
                annualInflation: 0.02,
                annualContributionGrowth: 0,
                targetAmount: 500_000,
                horizonMonths: 60,
                recoveryMonths: 24,
                monthlySpending: 3000
            )
        )
        #expect(abs(impact.portfolioChangePercent - -0.3) < 0.000_001)
        #expect(impact.endingValue == 70000)
        #expect(impact.recoveryMonths == 24)
        #expect((impact.requiredMonthlyContribution ?? 0) > 500)
        #expect((impact.contributionDelta ?? 0) > 0)
        #expect(impact.expenseImpactMonthly == impact.contributionDelta)
        #expect((impact.goalDelayMonths ?? -1) >= 0)
    }

    @Test
    func `custom processor emits impact fields with linked goal config`() {
        let snapshot: [String: ScenarioJSONValue] = [
            "total_value": .number(100_000),
            "base_currency": .string("USD"),
            "holdings": .array([
                .object([
                    "id": .string("h1"),
                    "value_in_base_currency": .number(100_000),
                    "asset_category": .string("stock"),
                    "currency": .string("USD"),
                ]),
            ]),
        ]
        let configuration: [String: ScenarioJSONValue] = [
            "asset_class_shocks": .array([
                .object(["target": .string("stock"), "percentage": .number(-0.3)]),
            ]),
            "horizon_months": .number(12),
            "recovery": .string("none"),
            "target_amount": .number(500_000),
            "monthly_contribution": .number(500),
            "annual_return": .number(0.07),
            "inflation": .number(0.02),
            "goal_horizon_months": .number(60),
            "monthly_spending": .number(2000),
        ]
        let result = ScenarioRunProcessor().custom(snapshot: snapshot, configuration: configuration).values
        #expect(abs((result["ending_value"]?.number ?? 0) - 70000) < 0.001)
        #expect(abs((result["portfolio_change_percent"]?.number ?? 0) - -0.3) < 0.000_001)
        #expect(abs((result["maximum_drawdown"]?.number ?? 0) - 0.3) < 0.000_001)
        #expect((result["required_monthly_contribution"]?.number ?? 0) > 500)
        #expect((result["contribution_delta"]?.number ?? 0) > 0)
        #expect(result["recovery_months"] == nil || result["recovery_months"] == .null)
    }

    @Test
    func `monthly simulation is seeded and includes goal analytics`() {
        let spec = ScenarioSimulationSpec(
            initialValue: 100_000, monthlyContribution: 500, annualContributionGrowth: 0.02,
            annualReturn: 0.07, annualVolatility: 0.15, annualInflation: 0.02,
            horizonMonths: 24, pathCount: 250, seed: 42, targetAmount: 120_000,
            distribution: .normal
        )
        let first = ScenarioEngine().simulate(spec)
        let second = ScenarioEngine().simulate(spec)
        #expect(first == second)
        #expect(first.bands.count == 25)
        #expect((first.goalProbability ?? -1) >= 0 && (first.goalProbability ?? 2) <= 1)
    }

    @Test
    func `bootstrap retains contiguous blocks`() {
        let output = ScenarioEngine().simulate(.init(
            initialValue: 100, monthlyContribution: 0, annualContributionGrowth: 0,
            annualReturn: 0, annualVolatility: 0, annualInflation: 0,
            horizonMonths: 6, pathCount: 10, seed: 7, targetAmount: nil,
            distribution: .blockBootstrap(monthlyReturns: [0.01, -0.02, 0.03], blockMonths: 2)
        ))
        #expect(output.bands.count == 7)
        #expect(output.goalProbability == nil)
    }

    @Test
    func `covariance repair makes an indefinite matrix decomposable`() {
        let engine = ScenarioEngine()
        let repaired = engine.repairedCovariance([[1, 2], [2, 1]])
        #expect(engine.cholesky(repaired) != nil)
        #expect(repaired[0][1] == repaired[1][0])
    }

    @Test
    func `correlated normal and student t paths are seeded`() {
        let base = CorrelatedScenarioSimulationSpec(
            initialValue: 100_000, weights: [0.6, 0.4], annualReturns: [0.08, 0.04],
            annualCovariance: [[0.04, 0.012], [0.012, 0.0225]], monthlyContribution: 100,
            annualContributionGrowth: 0, annualInflation: 0.02, horizonMonths: 24,
            pathCount: 200, seed: 99, targetAmount: 110_000, studentTDegreesOfFreedom: nil
        )
        #expect(ScenarioEngine().simulateCorrelated(base) == ScenarioEngine().simulateCorrelated(base))
        let student = CorrelatedScenarioSimulationSpec(
            initialValue: base.initialValue, weights: base.weights, annualReturns: base.annualReturns,
            annualCovariance: base.annualCovariance, monthlyContribution: base.monthlyContribution,
            annualContributionGrowth: base.annualContributionGrowth, annualInflation: base.annualInflation,
            horizonMonths: base.horizonMonths, pathCount: base.pathCount, seed: base.seed,
            targetAmount: base.targetAmount, studentTDegreesOfFreedom: 5
        )
        #expect(ScenarioEngine().simulateCorrelated(student).bands.count == 25)
    }

    @Test
    func `cross asset covariance changes portfolio dispersion`() throws {
        let common = (
            weights: [0.5, 0.5],
            returns: [0.06, 0.06],
            positive: [[0.04, 0.039], [0.039, 0.04]],
            negative: [[0.04, -0.039], [-0.039, 0.04]]
        )
        let positive = ScenarioEngine().simulateCorrelated(.init(
            initialValue: 100_000, weights: common.weights, annualReturns: common.returns,
            annualCovariance: common.positive, monthlyContribution: 0, annualContributionGrowth: 0,
            annualInflation: 0, horizonMonths: 12, pathCount: 5000, seed: 17,
            targetAmount: nil, studentTDegreesOfFreedom: nil
        ))
        let negative = ScenarioEngine().simulateCorrelated(.init(
            initialValue: 100_000, weights: common.weights, annualReturns: common.returns,
            annualCovariance: common.negative, monthlyContribution: 0, annualContributionGrowth: 0,
            annualInflation: 0, horizonMonths: 12, pathCount: 5000, seed: 17,
            targetAmount: nil, studentTDegreesOfFreedom: nil
        ))
        let positiveTerminal = try #require(positive.bands.last)
        let negativeTerminal = try #require(negative.bands.last)
        #expect(positiveTerminal.p90 - positiveTerminal.p10 > negativeTerminal.p90 - negativeTerminal.p10)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_SCENARIO_PERFORMANCE_TESTS"] == "true"))
    func `10,000 paths over 30 years and 50 assets complete within 30 seconds`() {
        let assetCount = 50
        let covariance = (0 ..< assetCount).map { row in
            (0 ..< assetCount).map { column in row == column ? 0.04 : 0.01 }
        }
        let started = Date()
        let output = ScenarioEngine().simulateCorrelated(.init(
            initialValue: 1_000_000,
            weights: Array(repeating: 1 / Double(assetCount), count: assetCount),
            annualReturns: Array(repeating: 0.07, count: assetCount),
            annualCovariance: covariance,
            monthlyContribution: 2000, annualContributionGrowth: 0.02,
            annualInflation: 0.02, horizonMonths: 360, pathCount: 10000,
            seed: 42, targetAmount: 4_000_000, studentTDegreesOfFreedom: nil
        ))
        let elapsed = Date().timeIntervalSince(started)
        #expect(output.bands.count == 361)
        #expect(elapsed < 30, "Acceptance workload took \(elapsed) seconds")
    }

    @Test
    func `zero covariance follows weighted expected return exactly`() throws {
        let output = ScenarioEngine().simulateCorrelated(.init(
            initialValue: 1000, weights: [0.75, 0.25], annualReturns: [0.12, 0],
            annualCovariance: [[0.000_000_000_1, 0], [0, 0.000_000_000_1]], monthlyContribution: 0,
            annualContributionGrowth: 0, annualInflation: 0, horizonMonths: 1,
            pathCount: 1000, seed: 4, targetAmount: nil, studentTDegreesOfFreedom: nil
        ))
        let median = try #require(output.bands.last).p50
        #expect(abs(median - 1007.5) < 0.1)
    }

    @Test
    func `inflation increases shortfall and reduces goal success`() {
        let common = ScenarioSimulationSpec(
            initialValue: 100, monthlyContribution: 0, annualContributionGrowth: 0,
            annualReturn: 0, annualVolatility: 0, annualInflation: 0,
            horizonMonths: 12, pathCount: 10, seed: 1, targetAmount: 100, distribution: .normal
        )
        let flat = ScenarioEngine().simulate(common)
        let inflated = ScenarioEngine().simulate(.init(
            initialValue: common.initialValue, monthlyContribution: common.monthlyContribution,
            annualContributionGrowth: common.annualContributionGrowth, annualReturn: common.annualReturn,
            annualVolatility: common.annualVolatility, annualInflation: 0.10,
            horizonMonths: common.horizonMonths, pathCount: common.pathCount, seed: common.seed,
            targetAmount: common.targetAmount, distribution: common.distribution
        ))
        #expect(flat.goalProbability == 1)
        #expect(inflated.goalProbability == 0)
        #expect((inflated.expectedShortfall ?? 0) > 0)
    }

    @Test
    func `custom scenario overrides broad shocks and attributes classes`() throws {
        let holdings: [ScenarioJSONValue] = [
            .object(["id": .string("equity"), "value_in_base_currency": .number(100), "asset_category": .string("stock"), "sector": .string("technology"), "currency": .string("USD")]),
            .object(["id": .string("bond"), "value_in_base_currency": .number(100), "asset_category": .string("bond"), "currency": .string("USD"), "duration": .number(5), "convexity": .number(20)]),
        ]
        let result = ScenarioRunProcessor().custom(
            snapshot: ["holdings": .array(holdings)],
            configuration: [
                "holding_shocks": .array([.object(["target": .string("equity"), "percentage": .number(-0.1)])]),
                "asset_class_shocks": .array([.object(["target": .string("stock"), "percentage": .number(-0.5)])]),
                "parallel_rate_shift_bps": .number(100), "horizon_months": .number(12), "recovery": .string("linear"),
            ]
        )
        let ending = try #require(result.values["ending_value"]?.number)
        #expect(abs(ending - 200) < 0.001)
        #expect(result.values["class_contributions"]?.array?.count == 2)
    }

    @Test
    func `custom rate shock uses versioned equity and REIT sensitivities`() throws {
        let holdings: [ScenarioJSONValue] = [
            .object([
                "id": .string("equity"), "value_in_base_currency": .number(100),
                "asset_category": .string("stock"), "currency": .string("USD"),
            ]),
            .object([
                "id": .string("reit"), "value_in_base_currency": .number(100),
                "asset_category": .string("real_estate"), "currency": .string("USD"),
                "factor_overrides": .object(["rate_sensitivity": .number(3)]),
            ]),
        ]
        let result = ScenarioRunProcessor().custom(
            snapshot: ["holdings": .array(holdings)],
            configuration: [
                "parallel_rate_shift_bps": .number(100), "volatility_multiplier": .number(1.5),
            ]
        )
        #expect(try abs(#require(result.values["ending_value"]?.number) - 195) < 0.001)
        #expect(result.values["assumptions"]?.object?["volatility_multiplier"]?.number == 1.5)
        #expect(result.values["assumptions"]?.object?["rate_sensitivity_defaults_version"]?.string == ScenarioEngine.version)
    }
}
