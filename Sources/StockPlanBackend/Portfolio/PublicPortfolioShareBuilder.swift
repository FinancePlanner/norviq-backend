import Foundation
import StockPlanShared

/// Turns a private valuation into what a stranger may see. Only ratios leave
/// this function: every input amount is divided by the portfolio total before
/// it is emitted, and nothing else is copied across.
enum PublicPortfolioShareBuilder {
    static let maxHoldings = 12

    static func build(valuation: PortfolioValuation, changes: PortfolioChanges?, asOf: String) -> PublicPortfolioShareResponse {
        let totals = PortfolioShareTotals(
            unrealizedPnlPercent: valuation.unrealizedPnlPercent.map(round2),
            dayChangePercent: valuation.dayChangePercent.map(round2),
            // PortfolioChange.percent is a fraction (-0.004 is -0.4%); every other
            // figure here is already in percentage points.
            ytdPercent: changes?.ytd.map { round2($0.percent * 100) }
        )
        guard valuation.totalValue > 0 else {
            return PublicPortfolioShareResponse(asOf: asOf, totals: totals, holdings: [], otherWeightPercent: nil)
        }

        var all = valuation.holdings.map { holding in
            PortfolioShareHolding(
                symbol: holding.symbol,
                weightPercent: holding.marketValue / valuation.totalValue * 100,
                unrealizedPnlPercent: holding.unrealizedPnlPercent.map(round2),
                dayChangePercent: holding.dayChangePercent.map(round2)
            )
        }
        if valuation.cashBalance > 0 {
            all.append(PortfolioShareHolding(
                symbol: "CASH",
                weightPercent: valuation.cashBalance / valuation.totalValue * 100,
                unrealizedPnlPercent: nil,
                dayChangePercent: nil
            ))
        }
        all.sort { $0.weightPercent > $1.weightPercent }

        let shown = all.prefix(maxHoldings).map { item in
            PortfolioShareHolding(
                symbol: item.symbol,
                weightPercent: round1(item.weightPercent),
                unrealizedPnlPercent: item.unrealizedPnlPercent,
                dayChangePercent: item.dayChangePercent
            )
        }
        let rest = all.dropFirst(maxHoldings).reduce(0) { $0 + $1.weightPercent }
        return PublicPortfolioShareResponse(
            asOf: asOf,
            totals: totals,
            holdings: Array(shown),
            otherWeightPercent: rest > 0 ? round1(rest) : nil
        )
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
