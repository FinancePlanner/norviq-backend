import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Wealth automation engines")
struct WealthAutomationEngineTests {
    @Test
    func `forecast applies income minus spending as a signed monthly flow`() {
        let output = ScenarioEngine().simulateNetFlow(.init(
            initialValue: 10000,
            monthlyIncome: 2000,
            monthlySpending: 2500,
            annualIncomeGrowth: 0,
            annualSpendingGrowth: 0,
            annualReturn: 0,
            annualVolatility: 0,
            annualInflation: 0,
            horizonMonths: 2,
            pathCount: 100,
            seed: 42,
            targetAmount: nil
        ))

        #expect(output.bands.map(\.p50) == [10000, 9500, 9000])
    }

    @Test
    func `forecast is reproducible for a supplied seed`() {
        let spec = NetFlowSimulationSpec(
            initialValue: 100_000,
            monthlyIncome: 4000,
            monthlySpending: 3000,
            annualIncomeGrowth: 0.01,
            annualSpendingGrowth: 0.02,
            annualReturn: 0.07,
            annualVolatility: 0.16,
            annualInflation: 0.02,
            horizonMonths: 24,
            pathCount: 500,
            seed: 7,
            targetAmount: 150_000
        )
        #expect(ScenarioEngine().simulateNetFlow(spec) == ScenarioEngine().simulateNetFlow(spec))
    }

    @Test
    func `screen treats missing data as an explained non-match`() throws {
        let condition = WatchlistScreenCondition(
            id: "margin", metric: "net_profit_margin", comparison: .improving, period: .quarterly
        )
        let descriptor = try #require(WatchlistScreenEvaluator.catalog.first { $0.id == condition.metric })
        let result = WatchlistScreenEvaluator().evaluate(
            condition: condition,
            observation: .init(current: nil, previous: nil),
            descriptor: descriptor
        )

        #expect(!result.matched)
        #expect(result.explanation.contains("No data"))
    }

    @Test
    func `lower leverage is improving`() throws {
        let condition = WatchlistScreenCondition(
            id: "debt", metric: "debt_to_equity", comparison: .improving, period: .annual
        )
        let descriptor = try #require(WatchlistScreenEvaluator.catalog.first { $0.id == condition.metric })
        let result = WatchlistScreenEvaluator().evaluate(
            condition: condition,
            observation: .init(current: 0.8, previous: 1.2),
            descriptor: descriptor
        )
        #expect(result.matched)
    }

    @Test
    func `rebalance uses live values and absolute percentage point drift`() throws {
        let policy = RebalancingPolicy(
            id: "policy",
            portfolioListId: "portfolio",
            cadence: .disabled,
            driftThreshold: 0.05,
            targets: [
                .init(id: "stock", kind: .symbol, symbol: "ACME", targetWeight: 0.6),
                .init(id: "cash", kind: .cash, targetWeight: 0.4),
            ]
        )
        let preview = try RebalancingEngine().preview(
            policy: policy,
            valuations: [
                .init(kind: .symbol, symbol: "ACME", value: 8000, price: 100),
                .init(kind: .cash, symbol: nil, value: 2000, price: nil),
            ],
            currency: "EUR"
        )

        #expect(abs(preview.maximumDrift - 0.2) < 0.000_001)
        #expect(preview.triggerReasons == [.drift])
        #expect(preview.trades.first?.action == .sell)
        #expect(preview.trades.first?.approximateShares == 20)
    }
}
