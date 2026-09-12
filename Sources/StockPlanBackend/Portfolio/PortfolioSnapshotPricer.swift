import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Aggregated positions plus the symbols a target allocation wants priced.
///
/// A symbol with zero quantity is a *price carrier*: it exists only so the
/// rebalancing engine can read a live price for a position the user does not own
/// yet. The engine requires every target leaf to appear in the snapshot, and it
/// does not clamp buys by held quantity, so a zero-quantity holding is the correct
/// way to price a from-scratch portfolio.
struct PortfolioPricingInput: Sendable {
    var quantityBySymbol: [String: Double]
    var basisBySymbol: [String: Double]
    var targetSymbols: [String]
    var cashByCurrency: [String: Double]
    var baseCurrency: String

    init(
        quantityBySymbol: [String: Double] = [:],
        basisBySymbol: [String: Double] = [:],
        targetSymbols: [String] = [],
        cashByCurrency: [String: Double] = [:],
        baseCurrency: String
    ) {
        self.quantityBySymbol = quantityBySymbol
        self.basisBySymbol = basisBySymbol
        self.targetSymbols = targetSymbols
        self.cashByCurrency = cashByCurrency
        self.baseCurrency = baseCurrency
    }
}

/// Turns aggregated positions into a priced `RebalancingValuationSnapshot`:
/// quote fetch, FX normalization, staleness classification, and the warnings that
/// go with each.
///
/// Extracted from `RebalancingService.valuation` so the rebalancer and the portfolio
/// simulator price portfolios the same way. Duplicating it would let the FX and
/// staleness rules drift apart silently, which is the kind of divergence nobody
/// notices until two screens disagree about the same portfolio.
struct PortfolioSnapshotPricer: Sendable {
    /// Quotes older than this are still used, but downgrade the snapshot to `.stale`.
    private let staleInterval: TimeInterval = 72 * 60 * 60

    func snapshot(_ input: PortfolioPricingInput, req: Request) async throws -> RebalancingValuationSnapshot {
        let baseCurrency = input.baseCurrency.uppercased()
        let symbols = Array(Set(input.quantityBySymbol.keys).union(input.targetSymbols)).sorted()
        let quotes = await fetchQuotes(symbols: symbols, req: req)

        var warnings = [RebalancingValuationWarning]()
        var quality = RebalancingPriceQuality.live
        var oldestPriceDate: Date?
        var rates: [String: Double] = [baseCurrency: 1]

        let currencies = Set(quotes.values.compactMap(\.currency).map { $0.uppercased() })
            .union(input.cashByCurrency.keys)
        for currency in currencies where currency != baseCurrency {
            do {
                let fx = try await req.application.marketDataService.fx(
                    pair: "\(currency)/\(baseCurrency)",
                    on: req
                )
                rates[currency] = fx.rate
            } catch {
                rates[currency] = 1
                quality = .incomplete
                warnings.append(
                    .init(code: "missing_fx", message: "Missing \(currency)/\(baseCurrency) exchange rate.")
                )
            }
        }

        let now = Date()
        var holdings = [RebalancingHolding]()
        for symbol in symbols {
            let quantity = input.quantityBySymbol[symbol, default: 0]
            let averageCost = quantity > 0 ? input.basisBySymbol[symbol, default: 0] / quantity : 0
            if let quote = quotes[symbol] {
                let date = Date(timeIntervalSince1970: quote.timestamp)
                oldestPriceDate = min(oldestPriceDate ?? date, date)
                if now.timeIntervalSince(date) > staleInterval, quality == .live {
                    quality = .stale
                    warnings.append(
                        .init(code: "stale_price", symbol: symbol, message: "The latest price for \(symbol) is stale.")
                    )
                }
                let rate = rates[quote.currency.uppercased(), default: 1]
                holdings.append(
                    .init(
                        symbol: symbol,
                        name: symbol,
                        quantity: quantity,
                        price: quote.currentPrice * rate,
                        averageCost: averageCost * rate
                    )
                )
            } else if quantity > 0 {
                // A held position with no quote still has to be valued, or the rest of
                // the portfolio silently reweights around it. Cost basis is the least
                // wrong stand-in.
                quality = .incomplete
                let fallback = averageCost > 0 ? averageCost : 0.01
                warnings.append(
                    .init(code: "missing_price", symbol: symbol, message: "No current price is available for \(symbol).")
                )
                holdings.append(
                    .init(symbol: symbol, name: symbol, quantity: quantity, price: fallback, averageCost: averageCost)
                )
            } else {
                // An unowned target with no price cannot be carried: there is no basis
                // to fall back on. It is dropped here and the caller is expected to
                // turn the warning into a 4xx rather than let the engine throw.
                quality = .incomplete
                warnings.append(
                    .init(
                        code: "missing_target_price",
                        symbol: symbol,
                        message: "No current price is available for target \(symbol)."
                    )
                )
            }
        }

        let cash = input.cashByCurrency.reduce(0) { total, item in
            total + item.value * rates[item.key, default: 1]
        }

        return .init(
            holdings: holdings,
            cash: cash,
            baseCurrency: input.baseCurrency,
            priceQuality: quality,
            pricedAt: formatISODateTime(oldestPriceDate),
            warnings: warnings
        )
    }

    /// Symbols the snapshot could not price at all. These are the ones a caller
    /// must reject on, because the engine will throw on any target it cannot price.
    func unpricedTargets(in snapshot: RebalancingValuationSnapshot) -> [String] {
        snapshot.warnings
            .filter { $0.code == "missing_target_price" }
            .compactMap(\.symbol)
            .sorted()
    }

    private func fetchQuotes(symbols: [String], req: Request) async -> [String: QuoteResponse] {
        guard !symbols.isEmpty else { return [:] }
        var result: [String: QuoteResponse] = [:]
        for start in stride(from: 0, to: symbols.count, by: 10) {
            let chunk = Array(symbols[start ..< min(start + 10, symbols.count)])
            let application = req.application
            let values = await withTaskGroup(of: QuoteResponse?.self) { group in
                for symbol in chunk {
                    group.addTask {
                        let child = Request(application: application, on: application.eventLoopGroup.next())
                        return try? await application.marketDataService.quote(symbol: symbol, on: child)
                    }
                }
                var values = [QuoteResponse]()
                for await value in group {
                    if let value {
                        values.append(value)
                    }
                }
                return values
            }
            for value in values {
                result[value.symbol.uppercased()] = value
            }
        }
        return result
    }
}
