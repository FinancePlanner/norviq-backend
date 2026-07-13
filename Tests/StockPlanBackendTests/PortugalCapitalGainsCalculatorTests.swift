import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Portugal annual capital gains")
struct PortugalCapitalGainsCalculatorTests {
    private let calculator = PortugalCapitalGainsCalculator()

    @Test
    func `nets annual gains and losses at autonomous rate`() {
        let result = calculator.calculate(
            positions: [.init(realizedPnL: 1000, holdingDays: 500), .init(realizedPnL: -400, holdingDays: 200)],
            estimatedTaxableIncome: 40000,
            marginalRate: 0.35,
            taxationMode: .autonomous,
            eligibleLossCarryforward: 0
        )
        #expect(result.annualBalance == 600)
        #expect(abs(result.estimatedTax - 168) < 0.000_001)
        #expect(!result.aggregationApplied)
    }

    @Test
    func `requires aggregation when short term balance reaches top band`() {
        let result = calculator.calculate(
            positions: [.init(realizedPnL: 2000, holdingDays: 100)],
            estimatedTaxableIncome: 85000,
            marginalRate: 0.48,
            taxationMode: .autonomous,
            eligibleLossCarryforward: 500
        )
        #expect(result.aggregationRequired)
        #expect(result.taxableBalance == 1500)
        #expect(result.estimatedTax == 720)
    }

    @Test
    func `carries losses only when aggregation applies`() {
        let aggregated = calculator.calculate(
            positions: [.init(realizedPnL: -900, holdingDays: 100)],
            estimatedTaxableIncome: 20000,
            marginalRate: 0.35,
            taxationMode: .aggregateWithIncome,
            eligibleLossCarryforward: 100
        )
        let autonomous = calculator.calculate(
            positions: [.init(realizedPnL: -900, holdingDays: 100)],
            estimatedTaxableIncome: 20000,
            marginalRate: 0.35,
            taxationMode: .autonomous,
            eligibleLossCarryforward: 100
        )
        #expect(aggregated.remainingLossCarryforward == 1000)
        #expect(autonomous.remainingLossCarryforward == 100)
    }
}
