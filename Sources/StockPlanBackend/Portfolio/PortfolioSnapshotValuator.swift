import Fluent
import Foundation
import SQLKit
import Vapor

/// What one portfolio list was worth on one day, for storage.
struct PortfolioSnapshotValuation: Sendable, Equatable {
    /// Σ shares × price over *priced* positions only. Unpriced positions are
    /// counted in `missingSymbols` and contribute nothing — see
    /// `PortfolioSnapshotValuator`.
    var marketValue: Double
    /// Σ shares × buy price over every position, priced or not.
    var costBasis: Double
    var cashBalance: Double
    var positionCount: Int
    var pricedSymbols: Int
    var missingSymbols: Int
    var currency: String

    /// True when every held symbol resolved a price, so `marketValue` covers the
    /// whole portfolio rather than part of it. A snapshot is only worth storing
    /// when this holds.
    var isFullyPriced: Bool {
        missingSymbols == 0
    }

    var totalValue: Double {
        marketValue + cashBalance
    }

    var isEmpty: Bool {
        positionCount == 0 && cashBalance == 0
    }
}

/// Where prices come from.
enum PortfolioSnapshotPricing: Sendable {
    /// Today: the quote cache, with the most recent bar as a fallback.
    case live
    /// A past day: bars only. Today's quote says nothing about what March was worth.
    case historical
}

/// Values a portfolio as of a given day, from stored price data, for the
/// purpose of recording history.
///
/// Distinct from `PortfolioValuationService`, and deliberately so. That one
/// answers "what is this worth right now" for display: it calls the market data
/// provider over the network, and when a quote is missing it falls back to the
/// average buy price so a dashboard still renders. Both choices are right there
/// and wrong here.
///
/// This one answers "what was this worth on day X" for storage, and is strict:
///
/// - Prices come from `market_price_bars` and `quote_cache`, never a network
///   call, so a year of backfill is a handful of queries rather than thousands.
/// - Adjusted closes, so a 2:1 split is not recorded as a 50% crash.
/// - A symbol that resolves no price is reported in `missingSymbols` and
///   contributes nothing to `marketValue`. It is never valued at cost. Folding
///   an unpriced position in at its buy price hides it inside the total with no
///   signal — which is exactly how a partially priced day comes to look like a
///   real move, the failure this work exists to remove.
struct PortfolioSnapshotValuator: Sendable {
    private let bars = MarketPriceBarRepository()

    /// How far back to look for the last close before a given day, covering
    /// weekends and holiday runs.
    private static let closeLookbackDays = 10

    // MARK: - Single day

    func value(
        userId: UUID,
        portfolioListId: UUID,
        asOf: Date,
        pricing: PortfolioSnapshotPricing,
        on db: any Database
    ) async throws -> PortfolioSnapshotValuation {
        let day = Self.startOfDay(asOf)
        let stocks = try await holdings(
            userId: userId,
            portfolioListId: portfolioListId,
            heldOn: pricing == .historical ? day : nil,
            on: db
        )
        let cash = try await cashBalance(
            userId: userId,
            portfolioListId: portfolioListId,
            on: db
        )
        guard !stocks.isEmpty else {
            return PortfolioSnapshotValuation(
                marketValue: 0,
                costBasis: 0,
                cashBalance: Self.round2(cash),
                positionCount: 0,
                pricedSymbols: 0,
                missingSymbols: 0,
                currency: "USD"
            )
        }

        let symbols = Self.uniqueSymbols(stocks.map(\.symbol))
        var prices = try await closes(symbols: symbols, on: day, on: db)
        var currency = "USD"

        if pricing == .live {
            // A same-day quote is fresher than the last stored bar, so it wins.
            let quotes = try await latestQuotes(symbols: symbols, on: db)
            for (symbol, quote) in quotes {
                prices[symbol] = quote.price
            }
            currency = quotes.values.first?.currency ?? "USD"
        }

        return Self.valuate(stocks: stocks, prices: prices, cash: cash, currency: currency)
    }

    // MARK: - Series

    /// Day-by-day historical valuation across a window, loading each symbol's
    /// prices exactly once.
    ///
    /// Calling `value(asOf:)` in a loop would issue a query per symbol per day —
    /// for a year of a twenty-symbol portfolio, several thousand round trips.
    ///
    /// Only days the market actually traded are returned. A day is taken to have
    /// traded when any held symbol has a bar for it; that infers the calendar
    /// from the data instead of hardcoding exchange holidays, and stays correct
    /// for whichever exchange the holdings sit on.
    func historicalSeries(
        userId: UUID,
        portfolioListId: UUID,
        from: Date,
        to: Date,
        on db: any Database
    ) async throws -> [(day: Date, valuation: PortfolioSnapshotValuation)] {
        let start = Self.startOfDay(from)
        let end = Self.startOfDay(to)
        guard start <= end else { return [] }

        let stocks = try await holdings(
            userId: userId,
            portfolioListId: portfolioListId,
            heldOn: end,
            on: db
        )
        guard !stocks.isEmpty else { return [] }

        let cash = try await cashBalance(
            userId: userId,
            portfolioListId: portfolioListId,
            on: db
        )
        let symbols = Self.uniqueSymbols(stocks.map(\.symbol))

        // Reach back before `start` so a window opening on a weekend or holiday
        // still resolves a price for its first day.
        let lookback = Self.addDays(start, days: -Self.closeLookbackDays)
        var seriesBySymbol: [String: [(date: Date, close: Double)]] = [:]
        for symbol in symbols {
            seriesBySymbol[symbol] = try await bars.adjustedCloses(
                instrumentKey: symbol, from: lookback, to: end, on: db
            )
        }

        var tradingDays = Set<Date>()
        for series in seriesBySymbol.values {
            for bar in series {
                let day = Self.startOfDay(bar.date)
                guard day >= start, day <= end else { continue }
                tradingDays.insert(day)
            }
        }

        return tradingDays.sorted().map { day in
            // A position cannot have been held before it was bought. This is what
            // makes a reconstructed curve grow as positions were added, rather
            // than projecting today's whole portfolio back through time.
            let held = stocks.filter { Self.startOfDay($0.buyDate) <= day }
            var prices: [String: Double] = [:]
            for (symbol, series) in seriesBySymbol {
                if let close = series.last(where: { Self.startOfDay($0.date) <= day })?.close {
                    prices[symbol] = close
                }
            }
            return (
                day,
                Self.valuate(stocks: held, prices: prices, cash: cash, currency: "USD")
            )
        }
    }

    // MARK: - The rule

    /// The valuation rule itself: pure, and therefore the part worth testing
    /// directly without a database.
    static func valuate(
        stocks: [Stock],
        prices: [String: Double],
        cash: Double,
        currency: String
    ) -> PortfolioSnapshotValuation {
        var marketValue = 0.0
        var costBasis = 0.0
        var priced = 0
        var missing = 0

        for stock in stocks {
            costBasis += stock.shares * stock.buyPrice
            let symbol = normalizePortfolioSymbol(stock.symbol)
            if let price = prices[symbol], price > 0 {
                marketValue += stock.shares * price
                priced += 1
            } else {
                missing += 1
            }
        }

        return PortfolioSnapshotValuation(
            marketValue: round2(marketValue),
            costBasis: round2(costBasis),
            cashBalance: round2(cash),
            positionCount: stocks.count,
            pricedSymbols: priced,
            missingSymbols: missing,
            currency: currency
        )
    }

    // MARK: - Loading

    private func holdings(
        userId: UUID,
        portfolioListId: UUID,
        heldOn day: Date?,
        on db: any Database
    ) async throws -> [Stock] {
        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId == portfolioListId)
            .all()
        guard let day else { return stocks }
        return stocks.filter { Self.startOfDay($0.buyDate) <= day }
    }

    struct QuoteSnapshot: Sendable {
        let currency: String
        let price: Double
    }

    /// Latest cached quote per symbol. Same "latest per symbol" SQL shape as
    /// `StatisticsRepository.loadLatestQuotes`, to avoid loading stale rows and
    /// deduping in memory.
    private func latestQuotes(
        symbols: [String],
        on db: any Database
    ) async throws -> [String: QuoteSnapshot] {
        guard !symbols.isEmpty, let sql = db as? any SQLDatabase else { return [:] }
        let rows = try await sql.raw(
            """
            SELECT DISTINCT ON (symbol)
                symbol,
                currency,
                price
            FROM quote_cache
            WHERE symbol = ANY(\(bind: symbols))
            ORDER BY symbol, as_of DESC
            """
        ).all()

        var result: [String: QuoteSnapshot] = [:]
        for row in rows {
            guard let symbol = try? row.decode(column: "symbol", as: String.self),
                  let price = try? row.decode(column: "price", as: Double.self),
                  price > 0
            else { continue }
            let currency = (try? row.decode(column: "currency", as: String.self)) ?? "USD"
            result[normalizePortfolioSymbol(symbol)] = QuoteSnapshot(
                currency: currency.uppercased(),
                price: price
            )
        }
        return result
    }

    /// Adjusted close on or before `day`, per symbol.
    private func closes(
        symbols: [String],
        on day: Date,
        on db: any Database
    ) async throws -> [String: Double] {
        var result: [String: Double] = [:]
        let from = Self.addDays(day, days: -Self.closeLookbackDays)
        for symbol in symbols {
            let series = try await bars.adjustedCloses(
                instrumentKey: symbol, from: from, to: day, on: db
            )
            if let close = series.last?.close, close > 0 {
                result[symbol] = close
            }
        }
        return result
    }

    /// Cash attributable to a portfolio: linked account balances plus manually
    /// recorded cash positions. Mirrors `PortfolioController.totalCashBalance`.
    ///
    /// There is no history to read here — `cash_balances` holds one current row
    /// per account — so a historical valuation necessarily holds today's cash
    /// constant. That is wrong by the same amount on every reconstructed day,
    /// which leaves the *shape* of the curve honest even though its level is
    /// not, and is why reconstructed rows are marked `backfill`.
    func cashBalance(
        userId: UUID,
        portfolioListId: UUID,
        on db: any Database
    ) async throws -> Double {
        let accountIds = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioId == portfolioListId)
            .all()
            .compactMap(\.id)

        let balances = accountIds.isEmpty
            ? []
            : try await CashBalance.query(on: db).filter(\.$accountId ~~ accountIds).all()

        var latestByAccountCurrency: [String: CashBalance] = [:]
        for balance in balances {
            let key = "\(balance.accountId.uuidString.lowercased())::\(balance.currency.uppercased())"
            if let existing = latestByAccountCurrency[key] {
                if balance.asOf > existing.asOf {
                    latestByAccountCurrency[key] = balance
                }
            } else {
                latestByAccountCurrency[key] = balance
            }
        }
        let accountCash = latestByAccountCurrency.values.reduce(0) { $0 + max(0, $1.balance) }

        let manualCash = try await PortfolioCashPositionRecord.query(on: db)
            .filter(\.$portfolioId == portfolioListId)
            .all()
            .reduce(0) { $0 + max(0, $1.balance) }

        return accountCash + manualCash
    }

    // MARK: - Helpers

    static func uniqueSymbols(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let symbol = normalizePortfolioSymbol(value)
            guard !symbol.isEmpty, !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            result.append(symbol)
        }
        return result
    }

    static func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.startOfDay(for: date)
    }

    static func addDays(_ date: Date, days: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
