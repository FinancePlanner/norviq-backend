import Foundation
import Vapor

// MARK: - /v1/market/insider/:symbol response

/// What an insider filing actually was, derived from the SEC transaction code.
///
/// `other` is everything the four categories do not cover (gifts, exempt
/// dispositions, in-kind transfers) and also covers a row that arrived with no
/// code at all. It is never a guess.
enum InsiderTradeKind: String, Codable, Sendable {
    /// SEC code `P` — an open-market purchase.
    case buy
    /// SEC code `S` — a sale.
    case sell
    /// SEC code `A` — a grant, award or other acquisition from the issuer.
    case award
    case other
}

struct InsiderTrade: Content, Equatable {
    /// Transaction date, `yyyy-MM-dd`.
    let date: String
    let reporterName: String
    /// The reporter's relationship to the issuer, as filed. Free text.
    let reporterTitle: String?
    /// The SEC transaction code exactly as it arrived, e.g. `P-Purchase`.
    let transactionType: String
    /// `transactionType` reduced to the four categories above.
    let kind: InsiderTradeKind
    let shares: Double
    let pricePerShare: Double?
    /// `shares × pricePerShare`. Null when the filing carried no price, which
    /// is normal for awards and gifts.
    let value: Double?
    /// Shares the reporter held after the transaction.
    let sharesOwnedAfter: Double?
    let filingURL: String?
}

/// Buy/sell counts and net flow over the requested window.
///
/// Awards and other non-market transactions are counted in neither `buys` nor
/// `sells` and move neither net figure: a grant is compensation, not a view on
/// the price.
struct InsiderActivitySummary: Content, Equatable {
    let buys: Int
    let sells: Int
    /// Bought shares minus sold shares.
    let netShares: Double
    /// Bought value minus sold value. Trades with no price contribute 0, so
    /// this is a floor on the real flow, not a complete total.
    let netValue: Double
}

/// Several different insiders buying on the open market in a short span — the
/// pattern that historically carries more signal than any one of them buying.
struct ClusterBuySignal: Content, Equatable {
    /// Distinct reporters who bought inside the window. Always at least 3.
    let insiderCount: Int
    /// Date of the earliest qualifying buy in the window, `yyyy-MM-dd`.
    let windowStart: String
    /// Date of the latest qualifying buy in the window, `yyyy-MM-dd`.
    let windowEnd: String
    /// Sum of the qualifying buys' values. Buys whose filing carried no price
    /// contribute 0, so this can be 0 even with a real cluster.
    let totalValue: Double
}

struct InsiderActivityResponse: Content, Equatable {
    let symbol: String
    /// The window actually used, in days, after clamping.
    let windowDays: Int
    /// Filings inside the window, newest transaction first. Empty when the
    /// symbol has none, or when the upstream plan does not cover insider data.
    let trades: [InsiderTrade]
    let summary: InsiderActivitySummary
    /// Null when no 30-day span inside the window holds open-market buys by
    /// three or more distinct reporters.
    let clusterBuy: ClusterBuySignal?
}

// MARK: - Configuration

enum InsiderActivityConfig {
    static let defaultWindowDays = 365
    static let windowDaysRange = 30 ... 1825
    /// Rolling span, in days, that a cluster buy has to fit inside. Inclusive
    /// of both ends: a buy exactly 30 days before the anchor still counts.
    static let clusterWindowDays = 30
    static let clusterMinimumInsiders = 3
    /// Hard ceiling on rows pulled from upstream, whatever the window asks for.
    static let maxRows = 500
    static let pageSize = 100

    /// Brings any requested window inside `windowDaysRange`.
    ///
    /// The HTTP route never needs this — it answers 400 for an out-of-range
    /// `days` before the service is called, because silently returning a
    /// different window than the one asked for is worse than refusing. The
    /// clamp is the service's own guarantee to its other callers and to the
    /// cache key, which must never be built from an unbounded number.
    /// Exercised through the service in `MarketOwnershipServiceTests`.
    static func clampWindowDays(_ requested: Int) -> Int {
        min(max(requested, windowDaysRange.lowerBound), windowDaysRange.upperBound)
    }

    static func redisKey(symbol: String, windowDays: Int) -> String {
        "market:insider:\(symbol):\(windowDays)"
    }
}

// MARK: - Calculation

enum InsiderActivity {
    /// Reduces an SEC transaction code to a category.
    ///
    /// Only the leading letter is read, because FMP returns both the bare code
    /// (`P`) and the expanded form (`P-Purchase`) depending on the endpoint and
    /// the row.
    static func kind(forTransactionType raw: String?) -> InsiderTradeKind {
        guard let first = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .first
        else {
            return .other
        }
        switch first {
        case "P": return .buy
        case "S": return .sell
        case "A": return .award
        default: return .other
        }
    }

    /// Converts one upstream row. Nil when the row has no transaction date:
    /// every window, sort and cluster decision here is made on that date, and
    /// substituting today's would invent one.
    static func trade(from wire: FMPInsiderTrade) -> InsiderTrade? {
        let date = wire.transactionDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !date.isEmpty else { return nil }

        let shares = wire.securitiesTransacted ?? 0
        // A zero price is FMP's way of saying "no price on this filing" — an
        // award is not a purchase at $0.00.
        let price = wire.price.flatMap { $0 > 0 ? $0 : nil }
        let name = wire.reportingName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return InsiderTrade(
            date: date,
            reporterName: name.isEmpty ? "Undisclosed insider" : name,
            reporterTitle: wire.typeOfOwner?.nonEmptyTrimmed,
            transactionType: wire.transactionType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            kind: kind(forTransactionType: wire.transactionType),
            shares: shares,
            pricePerShare: price,
            value: price.map { $0 * shares },
            sharesOwnedAfter: wire.securitiesOwned,
            filingURL: wire.url?.nonEmptyTrimmed
        )
    }

    static func summarize(_ trades: [InsiderTrade]) -> InsiderActivitySummary {
        var buys = 0
        var sells = 0
        var netShares = 0.0
        var netValue = 0.0

        for trade in trades {
            switch trade.kind {
            case .buy:
                buys += 1
                netShares += trade.shares
                netValue += trade.value ?? 0
            case .sell:
                sells += 1
                netShares -= trade.shares
                netValue -= trade.value ?? 0
            case .award, .other:
                continue
            }
        }
        return InsiderActivitySummary(buys: buys, sells: sells, netShares: netShares, netValue: netValue)
    }

    /// The most recent 30-day span holding open-market buys by three or more
    /// distinct reporters, or nil when there is none.
    ///
    /// Each buy's own date is tried as the end of the span, newest first, so
    /// the first span that qualifies is the most recent one. Reporters are
    /// matched on their filed name, case- and whitespace-insensitively; rows
    /// that arrived without a name all share the same placeholder, which can
    /// only make a cluster harder to reach, never easier.
    static func clusterBuy(in trades: [InsiderTrade]) -> ClusterBuySignal? {
        let buys = trades
            .filter { $0.kind == .buy }
            .compactMap { trade -> (day: Date, trade: InsiderTrade)? in
                guard let day = insiderDayFormatter.date(from: trade.date) else { return nil }
                return (day, trade)
            }
            .sorted { $0.day < $1.day }

        guard buys.count >= InsiderActivityConfig.clusterMinimumInsiders else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        for anchor in stride(from: buys.count - 1, through: 0, by: -1) {
            let end = buys[anchor].day
            guard let start = calendar.date(
                byAdding: .day,
                value: -InsiderActivityConfig.clusterWindowDays,
                to: end
            ) else { continue }

            let window = buys[...anchor].filter { $0.day >= start }
            let reporters = Set(window.map { normalizedReporter($0.trade.reporterName) })
            guard reporters.count >= InsiderActivityConfig.clusterMinimumInsiders,
                  let first = window.first
            else { continue }

            return ClusterBuySignal(
                insiderCount: reporters.count,
                windowStart: first.trade.date,
                windowEnd: buys[anchor].trade.date,
                totalValue: window.reduce(0) { $0 + ($1.trade.value ?? 0) }
            )
        }
        return nil
    }

    /// Assembles the response from raw upstream rows: drops rows outside the
    /// window, sorts newest first, and derives the summary and the signal.
    static func build(
        symbol: String,
        windowDays: Int,
        wire: [FMPInsiderTrade],
        asOf: Date = Date()
    ) -> InsiderActivityResponse {
        let window = InsiderActivityConfig.clampWindowDays(windowDays)
        let cutoff = cutoffDay(windowDays: window, asOf: asOf)
        let trades = wire
            .compactMap(trade(from:))
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }

        return InsiderActivityResponse(
            symbol: symbol,
            windowDays: window,
            trades: trades,
            summary: summarize(trades),
            clusterBuy: clusterBuy(in: trades)
        )
    }

    /// Oldest transaction date still inside the window, `yyyy-MM-dd`. Dates are
    /// compared as strings, which `yyyy-MM-dd` makes equivalent to comparing
    /// the days themselves.
    static func cutoffDay(windowDays: Int, asOf: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let start = calendar.date(byAdding: .day, value: -windowDays, to: asOf) ?? asOf
        return insiderDayFormatter.string(from: start)
    }

    private static func normalizedReporter(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

private let insiderDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

extension String {
    /// The trimmed string, or nil when nothing is left. Keeps an upstream `""`
    /// from reaching a client as a field that looks present but says nothing.
    /// Shared by the three ownership features (insider, congress,
    /// institutional), which all decode the same kind of sparse FMP rows.
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
