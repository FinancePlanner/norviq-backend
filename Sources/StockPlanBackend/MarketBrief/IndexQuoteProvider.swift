import Foundation
import Vapor

struct IndexQuote: Equatable, Sendable {
    let symbol: String
    let price: Double
    let previousClose: Double
    /// When the price was last updated at its exchange.
    let marketTime: Date

    var changePercent: Double {
        (price / previousClose - 1) * 100
    }
}

/// Index, futures, yield and commodity levels for the market brief.
protocol IndexQuoteProvider: Sendable {
    /// Never throws. A symbol that fails, is unknown or is stale is left out,
    /// so one bad row never costs the whole brief.
    func quotes(symbols: [String], now: Date, on req: Request) async -> [IndexQuote]
}

/// Yahoo's public chart endpoint. Unofficial and keyless: it can rate-limit
/// or start demanding a cookie, which is why it sits behind a protocol and
/// why every failure degrades to a missing row.
///
/// `range=1d` is load-bearing. With `range=5d`, `meta.chartPreviousClose` is
/// the close from *before the five-day window*, not yesterday's close, and
/// every percentage is wrong (checked 2026-10-08).
struct YahooChartQuoteProvider: IndexQuoteProvider {
    static let defaultBaseURL = "https://query1.finance.yahoo.com/v8/finance/chart/"
    /// Older than this, the row would show a previous session's move as today's.
    /// It also drops a market that is shut for a holiday.
    static let maxAge: TimeInterval = 18 * 3600
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    let baseURL: String

    init(baseURL: String = Self.defaultBaseURL) {
        self.baseURL = baseURL
    }

    func quotes(symbols: [String], now: Date, on req: Request) async -> [IndexQuote] {
        var result: [IndexQuote] = []
        // Sequential on purpose: about a dozen calls twice a day does not need
        // concurrency, and a burst is what gets an IP throttled.
        for symbol in symbols {
            do {
                guard let quote = try await fetch(symbol, on: req) else {
                    req.logger.warning("market_brief_quote_missing", metadata: ["symbol": .string(symbol)])
                    continue
                }
                guard Self.isFresh(quote, now: now) else {
                    req.logger.info("market_brief_quote_stale", metadata: ["symbol": .string(symbol)])
                    continue
                }
                result.append(quote)
            } catch {
                req.logger.warning(
                    "market_brief_quote_failed",
                    metadata: ["symbol": .string(symbol), "error": .string(String(describing: error))]
                )
            }
        }
        return result
    }

    static func isFresh(_ quote: IndexQuote, now: Date) -> Bool {
        now.timeIntervalSince(quote.marketTime) <= maxAge
    }

    static func parse(_ data: Data) throws -> IndexQuote? {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let meta = envelope.chart.result?.first?.meta,
              let price = meta.regularMarketPrice, price.isFinite, price > 0,
              let previous = meta.chartPreviousClose, previous.isFinite, previous > 0,
              let time = meta.regularMarketTime
        else { return nil }
        return IndexQuote(
            symbol: meta.symbol,
            price: price,
            previousClose: previous,
            marketTime: Date(timeIntervalSince1970: time)
        )
    }

    private func fetch(_ symbol: String, on req: Request) async throws -> IndexQuote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
        let response = try await req.client.get(URI(string: "\(baseURL)\(encoded)?range=1d&interval=1d")) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .userAgent, value: Self.userAgent)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(8)
        }
        guard let body = response.body else { return nil }
        return try Self.parse(Data(buffer: body))
    }

    private struct Envelope: Decodable {
        let chart: Chart

        struct Chart: Decodable {
            let result: [Result]?
        }

        struct Result: Decodable {
            let meta: Meta
        }

        struct Meta: Decodable {
            let symbol: String
            let regularMarketPrice: Double?
            let chartPreviousClose: Double?
            let regularMarketTime: Double?
        }
    }
}
