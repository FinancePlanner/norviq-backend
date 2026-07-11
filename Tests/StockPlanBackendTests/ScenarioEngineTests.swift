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
}
