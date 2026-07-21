import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Normalizes a raw stock symbol the same way across the portfolio feature
/// (trim whitespace, uppercase). Single shared definition so aggregation by
/// symbol is consistent between `PortfolioController` and
/// `PortfolioValuationService`.
func normalizePortfolioSymbol(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

struct HoldingValuation: Sendable {
    let symbol: String // normalized (uppercased/trimmed) symbol
    let shares: Double
    let costBasis: Double // Σ shares*buyPrice across merged rows
    let averageBuyPrice: Double // costBasis/shares (0 when shares==0)
    let currentPrice: Double? // quote.currentPrice; nil when no live quote
    let marketValue: Double // shares * (currentPrice ?? averageBuyPrice)
    let unrealizedPnl: Double // marketValue - costBasis
    let unrealizedPnlPercent: Double? // costBasis>0 ? unrealizedPnl/costBasis*100 : nil
    let dayChange: Double? // quote.change != nil ? change*shares : nil
    let dayChangePercent: Double? // quote.percentChange
    let hasLiveQuote: Bool
}

struct PortfolioValuation: Sendable {
    let holdings: [HoldingValuation] // sorted by marketValue desc, shares>0 only
    let holdingsMarketValue: Double // Σ marketValue
    let totalCost: Double // Σ costBasis
    let unrealizedPnl: Double // Σ unrealizedPnl
    let unrealizedPnlPercent: Double? // totalCost>0 ? unrealizedPnl/totalCost*100 : nil
    let dayChange: Double // Σ (dayChange ?? 0)
    let cashBalance: Double // caller passes in (see below)
    let totalValue: Double // holdingsMarketValue + max(0, cashBalance)
    let dayChangePercent: Double? // prev = totalValue - dayChange; prev>0 ? dayChange/prev*100 : nil
    let asOf: Date
}

protocol PortfolioValuationService: Sendable {
    /// Values the given stock rows against live quotes. Rows should already be
    /// scoped to the user/portfolio by the caller. `cashBalance` is passed in
    /// (callers resolve it via their own filter). Quotes are best-effort — a
    /// provider outage degrades price-dependent fields, never throws.
    func value(stocks: [Stock], cashBalance: Double, asOf: Date, on req: Request) async throws -> PortfolioValuation
}

struct DefaultPortfolioValuationService: PortfolioValuationService {
    private struct SymbolPosition {
        var shares: Double = 0
        var costBasis: Double = 0
    }

    func value(stocks: [Stock], cashBalance: Double, asOf: Date, on req: Request) async throws -> PortfolioValuation {
        var positions: [String: SymbolPosition] = [:]
        var symbolOrder: [String] = []
        for stock in stocks {
            let symbol = normalizePortfolioSymbol(stock.symbol)
            guard !symbol.isEmpty else { continue }
            if positions[symbol] == nil {
                symbolOrder.append(symbol)
            }
            var position = positions[symbol] ?? SymbolPosition()
            position.shares += stock.shares
            position.costBasis += stock.shares * stock.buyPrice
            positions[symbol] = position
        }

        // Quotes are best-effort: a provider outage (or the disabled provider)
        // must not break valuation — price-dependent fields degrade to nil instead.
        var quotesBySymbol: [String: QuoteResponse] = [:]
        let batchLimit = 100
        for chunkStart in stride(from: 0, to: symbolOrder.count, by: batchLimit) {
            let chunk = Array(symbolOrder[chunkStart ..< min(chunkStart + batchLimit, symbolOrder.count)])
            do {
                let batch = try await req.application.marketDataService.quoteBatch(symbols: chunk, on: req)
                for quote in batch.quotes {
                    quotesBySymbol[normalizePortfolioSymbol(quote.symbol)] = quote
                }
            } catch {
                req.logger.warning("portfolio-valuation: quote batch unavailable for \(chunk.count) symbols: \(String(reflecting: error))")
            }
        }

        var holdings: [HoldingValuation] = []
        for symbol in symbolOrder {
            guard let position = positions[symbol], position.shares > 0 else { continue }
            let quote = quotesBySymbol[symbol]
            let averageBuyPrice = position.costBasis / position.shares
            let price = quote?.currentPrice ?? averageBuyPrice
            let marketValue = position.shares * price
            let unrealizedPnl = marketValue - position.costBasis

            holdings.append(
                HoldingValuation(
                    symbol: symbol,
                    shares: position.shares,
                    costBasis: position.costBasis,
                    averageBuyPrice: averageBuyPrice,
                    currentPrice: quote?.currentPrice,
                    marketValue: marketValue,
                    unrealizedPnl: unrealizedPnl,
                    unrealizedPnlPercent: position.costBasis > 0 ? (unrealizedPnl / position.costBasis) * 100 : nil,
                    dayChange: quote?.change.map { $0 * position.shares },
                    dayChangePercent: quote?.percentChange,
                    hasLiveQuote: quote != nil
                )
            )
        }
        holdings.sort { $0.marketValue > $1.marketValue }

        let holdingsMarketValue = holdings.reduce(0.0) { $0 + $1.marketValue }
        let totalCost = holdings.reduce(0.0) { $0 + $1.costBasis }
        let unrealizedPnl = holdings.reduce(0.0) { $0 + $1.unrealizedPnl }
        let dayChange = holdings.reduce(0.0) { $0 + ($1.dayChange ?? 0) }
        let totalValue = holdingsMarketValue + max(0, cashBalance)
        let previousTotalValue = totalValue - dayChange

        return PortfolioValuation(
            holdings: holdings,
            holdingsMarketValue: holdingsMarketValue,
            totalCost: totalCost,
            unrealizedPnl: unrealizedPnl,
            unrealizedPnlPercent: totalCost > 0 ? (unrealizedPnl / totalCost) * 100 : nil,
            dayChange: dayChange,
            cashBalance: cashBalance,
            totalValue: totalValue,
            dayChangePercent: previousTotalValue > 0 ? (dayChange / previousTotalValue) * 100 : nil,
            asOf: asOf
        )
    }
}
