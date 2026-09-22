import Foundation
import StockPlanShared

/// Personal mark for a memo. Every figure here is arithmetic on the evidence
/// pack. The writing model is not allowed to replace it.
enum PositionMemoMath {
    struct QuoteInput: Equatable, Sendable {
        var symbol: String
        var price: Double
        var currency: String
    }

    struct Input: Equatable, Sendable {
        var askedSymbol: String
        var primarySymbol: String
        var statedCost: Double?
        var statedCurrency: String?
        var statedPercent: Double?
        var live: QuoteInput?
        var primary: QuoteInput?
        /// Cost-currency units per one unit of the live quote currency.
        var fxRate: Double?
        var fxPair: String?
        var fxDate: String?
        var shares: Double?
        var lotAveragePrice: Double?
    }

    static func mark(_ input: Input) -> PositionMemoMark {
        let lotAverage = input.lotAveragePrice.flatMap { $0 > 0 ? $0 : nil }
        let stated = input.statedCost.flatMap { $0 > 0 ? $0 : nil }
        let cost = stated ?? lotAverage
        let costSource = if stated != nil {
            "stated"
        } else if lotAverage != nil {
            "lots"
        } else {
            "none"
        }
        let costCurrency = stated != nil ? input.statedCurrency : nil

        let live = input.live ?? input.primary
        let priceInCost = converted(live: live, costCurrency: costCurrency, fxRate: input.fxRate)
        let drawdown = percentChange(from: cost, to: priceInCost)
        let implied = impliedPrice(cost: cost, statedPercent: input.statedPercent)
        let breakeven = breakevenPercent(cost: cost, price: priceInCost)

        return PositionMemoMark(
            cost: cost,
            costCurrency: costCurrency ?? live?.currency,
            costSource: costSource,
            liveSymbol: live?.symbol,
            livePrice: live?.price,
            liveCurrency: live?.currency,
            primarySymbol: input.primary?.symbol ?? input.primarySymbol,
            primaryPrice: input.primary?.price,
            primaryCurrency: input.primary?.currency,
            fxPair: priceInCost == nil ? nil : input.fxPair,
            fxRate: currenciesMatch(live?.currency, costCurrency) ? nil : input.fxRate,
            fxDate: currenciesMatch(live?.currency, costCurrency) ? nil : input.fxDate,
            priceInCostCurrency: priceInCost,
            drawdownPercent: drawdown,
            statedPercent: input.statedPercent,
            priceImpliedByStatedPercent: implied,
            breakevenPercent: breakeven,
            shares: input.shares,
            lotAveragePrice: lotAverage
        )
    }

    static func oneDecimal(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func threeDecimal(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    /// Pair whose rate converts `from` into `to`. `USDEUR` means euros per dollar.
    static func fxPair(from: String, to: String) -> String {
        from.uppercased() + to.uppercased()
    }

    private static func converted(live: QuoteInput?, costCurrency: String?, fxRate: Double?) -> Double? {
        guard let live else { return nil }
        guard let costCurrency, !currenciesMatch(live.currency, costCurrency) else { return live.price }
        guard let fxRate, fxRate > 0 else { return nil }
        return live.price * fxRate
    }

    private static func currenciesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func percentChange(from cost: Double?, to price: Double?) -> Double? {
        guard let cost, let price, cost > 0 else { return nil }
        return ((price / cost) - 1) * 100
    }

    private static func impliedPrice(cost: Double?, statedPercent: Double?) -> Double? {
        guard let cost, cost > 0, let statedPercent else { return nil }
        return cost * (1 + statedPercent / 100)
    }

    private static func breakevenPercent(cost: Double?, price: Double?) -> Double? {
        guard let cost, let price, price > 0 else { return nil }
        return ((cost / price) - 1) * 100
    }
}
