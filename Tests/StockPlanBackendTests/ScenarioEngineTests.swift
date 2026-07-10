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
        #expect(ScenarioEngine().customValue(for: holding, shocks: shocks) == 60)
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
}
