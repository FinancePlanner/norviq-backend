import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Public portfolio share builder")
struct PublicPortfolioShareBuilderTests {
    private func holding(_ symbol: String, value: Double, pnlPct: Double? = 10, dayPct: Double? = 1) -> HoldingValuation {
        HoldingValuation(
            symbol: symbol, shares: 1, costBasis: value, averageBuyPrice: value, currentPrice: value,
            marketValue: value, unrealizedPnl: 0, unrealizedPnlPercent: pnlPct, dayChange: 0,
            dayChangePercent: dayPct, hasLiveQuote: true
        )
    }

    private func valuation(_ holdings: [HoldingValuation], cash: Double = 0) -> PortfolioValuation {
        let hv = holdings.reduce(0) { $0 + $1.marketValue }
        return PortfolioValuation(
            holdings: holdings, holdingsMarketValue: hv, totalCost: hv, unrealizedPnl: 0,
            unrealizedPnlPercent: 5, dayChange: 0, cashBalance: cash, totalValue: hv + max(0, cash),
            dayChangePercent: 0.5, asOf: Date()
        )
    }

    @Test("Weights are percent of total incl. cash, sorted desc")
    func weights() {
        let out = PublicPortfolioShareBuilder.build(
            valuation: valuation([holding("MSFT", value: 300), holding("AAPL", value: 600)], cash: 100),
            changes: nil, asOf: "2026-09-24"
        )
        #expect(out.holdings.map(\.symbol) == ["AAPL", "MSFT", "CASH"])
        #expect(out.holdings.map(\.weightPercent) == [60, 30, 10])
        #expect(out.holdings.last?.unrealizedPnlPercent == nil)
        #expect(out.otherWeightPercent == nil)
        #expect(out.totals.unrealizedPnlPercent == 5)
    }

    @Test("More than 12 holdings fold into Other and sum to 100")
    func foldsIntoOther() throws {
        let many = (0 ..< 20).map { holding("S\($0)", value: Double(100 - $0)) }
        let out = PublicPortfolioShareBuilder.build(valuation: valuation(many), changes: nil, asOf: "2026-09-24")
        #expect(out.holdings.count == 12)
        let other = try #require(out.otherWeightPercent)
        let sum = out.holdings.reduce(0) { $0 + $1.weightPercent } + other
        #expect(abs(sum - 100) < 0.2)
    }

    @Test("Empty portfolio yields no holdings and no NaN")
    func empty() {
        let out = PublicPortfolioShareBuilder.build(valuation: valuation([]), changes: nil, asOf: "2026-09-24")
        #expect(out.holdings.isEmpty)
        #expect(out.otherWeightPercent == nil)
    }

    @Test("Cash-only portfolio is CASH 100")
    func cashOnly() {
        let out = PublicPortfolioShareBuilder.build(valuation: valuation([], cash: 500), changes: nil, asOf: "2026-09-24")
        #expect(out.holdings == [PortfolioShareHolding(symbol: "CASH", weightPercent: 100, unrealizedPnlPercent: nil, dayChangePercent: nil)])
    }

    @Test("Encoded JSON never contains money keys")
    func noMoneyKeys() throws {
        let out = PublicPortfolioShareBuilder.build(valuation: valuation([holding("AAPL", value: 123_456.78)]), changes: nil, asOf: "2026-09-24")
        let json = try String(decoding: JSONEncoder().encode(out), as: UTF8.self)
        for banned in ["value", "Value", "cost", "shares", "price", "currency", "123456"] {
            #expect(!json.contains(banned), "leaked \(banned)")
        }
    }
}
