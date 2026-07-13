@testable import StockPlanBackend
import Testing

@Suite("Germany capital gains calculator")
struct GermanyCapitalGainsCalculatorTests {
    @Test("nets current-year stock gains and losses")
    func netsCurrentYearStockResults() {
        let result = GermanyCapitalGainsCalculator.calculate(
            realizedStockResults: [10000, -4000, 2000]
        )

        #expect(result.stockGains == 12000)
        #expect(result.currentYearStockLosses == 4000)
        #expect(result.taxableStockGains == 8000)
        #expect(result.endingStockLossCarryforward == 0)
        #expect(result.estimatedTax == 2110)
    }

    @Test("applies prior stock losses only up to current stock gains")
    func appliesPriorStockLossCarryforward() {
        let result = GermanyCapitalGainsCalculator.calculate(
            realizedStockResults: [7000],
            priorStockLossCarryforward: 10000
        )

        #expect(result.priorStockLossApplied == 7000)
        #expect(result.taxableStockGains == 0)
        #expect(result.endingStockLossCarryforward == 3000)
        #expect(result.estimatedTax == 0)
    }

    @Test("carries unused current-year stock losses forward")
    func carriesCurrentYearStockLossForward() {
        let result = GermanyCapitalGainsCalculator.calculate(
            realizedStockResults: [2000, -5500],
            priorStockLossCarryforward: 1000
        )

        #expect(result.taxableStockGains == 0)
        #expect(result.endingStockLossCarryforward == 4500)
    }
}
