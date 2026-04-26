@testable import StockPlanBackend
import Testing
import Vapor

@Suite("MarketDataService DCF Tests", .serialized)
struct MarketDataServiceTests {
    @Test("DCF math with explicit positive cash flows")
    func dCFMathPositiveFlows() throws {
        let projections = [
            YearlyProjectionResponse(year: 2026, revenue: 100, revenueGrowth: 0.1, netIncome: 20, netIncomeGrowth: 0.1, netMargin: 0.2, eps: 2, fcf: 10, fcfMargin: 0.1),
            YearlyProjectionResponse(year: 2027, revenue: 110, revenueGrowth: 0.1, netIncome: 22, netIncomeGrowth: 0.1, netMargin: 0.2, eps: 2.2, fcf: 11, fcfMargin: 0.1),
            YearlyProjectionResponse(year: 2028, revenue: 121, revenueGrowth: 0.1, netIncome: 24.2, netIncomeGrowth: 0.1, netMargin: 0.2, eps: 2.42, fcf: 12.1, fcfMargin: 0.1),
        ]
        let shares = 10.0
        let wacc = 0.10
        let terminalGrowth = 0.02
        let netDebt = 50.0

        let price = DefaultMarketDataService.calculateDCFPrice(
            projections: projections,
            sharesOutstanding: shares,
            wacc: wacc,
            terminalGrowthRate: terminalGrowth,
            netDebt: netDebt
        )

        // pvExplicit = 10/(1.1) + 11/(1.1^2) + 12.1/(1.1^3) = 9.0909 + 9.0909 + 9.0909 = 27.2727
        // finalFCF = 12.1
        // tv = 12.1 * 1.02 / (0.10 - 0.02) = 12.342 / 0.08 = 154.275
        // pvTerminal = 154.275 / (1.1^3) = 154.275 / 1.331 = 115.909
        // total pv = 27.2727 + 115.909 = 143.1818
        // equity = 143.1818 - 50 = 93.1818
        // per share = 93.1818 / 10 = 9.318

        let p = try #require(price)
        #expect(abs(p - 9.318) < 0.01)
    }

    @Test("DCF math handles zero shares correctly")
    func dCFMathZeroShares() {
        let projections = [
            YearlyProjectionResponse(year: 2026, revenue: 100, revenueGrowth: 0.1, netIncome: 20, netIncomeGrowth: 0.1, netMargin: 0.2, eps: 2, fcf: 10, fcfMargin: 0.1),
        ]

        let price = DefaultMarketDataService.calculateDCFPrice(
            projections: projections,
            sharesOutstanding: 0.0,
            wacc: 0.10,
            terminalGrowthRate: 0.02,
            netDebt: 0.0
        )
        #expect(price == nil)
    }

    @Test("DCF math handles missing shares correctly")
    func dCFMathMissingShares() {
        let projections = [
            YearlyProjectionResponse(year: 2026, revenue: 100, revenueGrowth: 0.1, netIncome: 20, netIncomeGrowth: 0.1, netMargin: 0.2, eps: 2, fcf: 10, fcfMargin: 0.1),
        ]

        let price = DefaultMarketDataService.calculateDCFPrice(
            projections: projections,
            sharesOutstanding: nil,
            wacc: 0.10,
            terminalGrowthRate: 0.02,
            netDebt: 0.0
        )
        #expect(price == nil)
    }

    @Test("DCF math with zero revenue growth and zero fcf")
    func dCFMathZeroFCF() throws {
        let projections = [
            YearlyProjectionResponse(year: 2026, revenue: 100, revenueGrowth: 0.0, netIncome: 0, netIncomeGrowth: 0.0, netMargin: 0.0, eps: 0, fcf: 0, fcfMargin: 0.0),
        ]

        let price = DefaultMarketDataService.calculateDCFPrice(
            projections: projections,
            sharesOutstanding: 10.0,
            wacc: 0.10,
            terminalGrowthRate: 0.02,
            netDebt: 10.0
        )

        // PV = 0, TV = 0. Equity = 0 - 10 = -10. Per share = -1.0
        let p = try #require(price)
        #expect(abs(p - -1.0) < 0.01)
    }
}
