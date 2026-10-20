import Foundation
import Vapor

/// One session's close, dated in the exchange's own time zone.
struct DailyBar: Equatable, Sendable {
    let date: String // yyyy-MM-dd
    let close: Double
}

/// Up to two years of closes, oldest first. Returns are worked out here, from the
/// bars, so a post never asks the model to do arithmetic.
struct DailyBarSeries: Equatable, Sendable {
    let symbol: String
    var currency: String?
    let bars: [DailyBar]

    var last: DailyBar? {
        bars.last
    }

    /// From the close `sessions` bars back to the latest close: 1 is the
    /// last session's move, 5 about a week.
    func percentChange(sessionsBack sessions: Int) -> Double? {
        guard sessions > 0, bars.count > sessions, let last else { return nil }
        let base = bars[bars.count - 1 - sessions].close
        guard base > 0 else { return nil }
        return (last.close / base - 1) * 100
    }

    /// From the last close before `day` to the latest close. `day` is
    /// yyyy-MM-dd: "2026-01-01" gives YTD, a Monday gives the week. Nil when
    /// the series does not reach back that far.
    func percentChange(sinceCloseBefore day: String) -> Double? {
        guard let last, let base = bars.last(where: { $0.date < day }), base.close > 0 else { return nil }
        return (last.close / base.close - 1) * 100
    }

    /// Closing high and low over the year to the latest bar. Closes, not
    /// intraday extremes: label them that way.
    var high52: Double? {
        lastYear.map(\.close).max()
    }

    var low52: Double? {
        lastYear.map(\.close).min()
    }

    private var lastYear: [DailyBar] {
        guard let last, let cutoff = Self.dayOneYearBefore(last.date) else { return [] }
        return bars.filter { $0.date > cutoff }
    }

    private static func dayOneYearBefore(_ day: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: day),
              let earlier = Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: date)
        else { return nil }
        return formatter.string(from: earlier)
    }
}

protocol DailyBarsProvider: Sendable {
    /// Never throws. Nil when the symbol fails or has no bars.
    func series(symbol: String, on req: Request) async -> DailyBarSeries?
}

/// The same Yahoo chart endpoint as `YahooChartQuoteProvider`, over two years
/// of daily bars: one year is not enough for a one-year change, which needs
/// the close from before the window opened. Only the bars are read: with any range over one day,
/// `meta.chartPreviousClose` is the close before the window, not yesterday's.
///
/// No freshness cutoff here, unlike the quote provider. Weekend and holiday
/// posts are written from the last session on purpose.
struct YahooDailyBarsProvider: DailyBarsProvider {
    let baseURL: String

    init(baseURL: String = YahooChartQuoteProvider.defaultBaseURL) {
        self.baseURL = baseURL
    }

    func series(symbol: String, on req: Request) async -> DailyBarSeries? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
        do {
            let response = try await req.client.get(URI(string: "\(baseURL)\(encoded)?range=2y&interval=1d")) { clientRequest in
                clientRequest.headers.replaceOrAdd(name: .userAgent, value: YahooChartQuoteProvider.userAgent)
                clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
                clientRequest.timeout = .seconds(8)
            }
            guard let body = response.body else { return nil }
            return try Self.parse(Data(buffer: body))
        } catch {
            req.logger.warning(
                "daily_bars_failed",
                metadata: ["symbol": .string(symbol), "error": .string(String(describing: error))]
            )
            return nil
        }
    }

    static func parse(_ data: Data) throws -> DailyBarSeries? {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let result = envelope.chart.result?.first,
              let timestamps = result.timestamp,
              let closes = result.indicators?.quote?.first?.close
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = result.meta.exchangeTimezoneName.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let bars = zip(timestamps, closes).compactMap { time, close -> DailyBar? in
            guard let close, close.isFinite, close > 0 else { return nil }
            return DailyBar(date: formatter.string(from: Date(timeIntervalSince1970: time)), close: close)
        }
        guard !bars.isEmpty else { return nil }
        return DailyBarSeries(
            symbol: result.meta.symbol,
            currency: result.meta.currency,
            bars: bars.sorted { $0.date < $1.date }
        )
    }

    private struct Envelope: Decodable {
        let chart: Chart

        struct Chart: Decodable {
            let result: [Result]?
        }

        struct Result: Decodable {
            let meta: Meta
            let timestamp: [Double]?
            let indicators: Indicators?
        }

        struct Meta: Decodable {
            let symbol: String
            let currency: String?
            let exchangeTimezoneName: String?
        }

        struct Indicators: Decodable {
            let quote: [Quote]?
        }

        struct Quote: Decodable {
            let close: [Double?]?
        }
    }
}
