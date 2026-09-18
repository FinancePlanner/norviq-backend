import Foundation
import StockPlanShared
import Vapor

// MARK: - /v1/market/technicals/:symbol response

/// Where the last close sits relative to *both* moving averages.
///
/// `mixed` also covers "not knowable": with fewer than 200 sessions the 200-day
/// average is nil, so the close cannot be shown to be above or below both.
enum TechnicalTrend: String, Codable, Sendable {
    case aboveBoth
    case belowBoth
    case mixed
}

/// Whether the 50/200 relationship flipped inside the recent-cross window.
/// `none` means "no flip in that window", not "no data".
enum TechnicalCross: String, Codable, Sendable {
    case goldenCross
    case deathCross
    case none
}

/// Sign of the MACD histogram — the line's position against its own signal,
/// which is the bullish/bearish reading a reader expects from "MACD is
/// positive". Not the sign of the MACD line against zero.
enum TechnicalMACDSign: String, Codable, Sendable {
    case positive
    case negative
}

struct TechnicalMACD: Content, Equatable {
    /// 12-period EMA minus 26-period EMA.
    let line: Double
    /// 9-period EMA of `line`.
    let signal: Double
    /// `line - signal`.
    let histogram: Double
    let sign: TechnicalMACDSign
}

struct TechnicalFiftyTwoWeek: Content, Equatable {
    let high: Double
    let low: Double
    /// 0–100: where the last close sits between `low` and `high`.
    let positionPct: Double
}

/// Trend, momentum, and range signals derived from daily candles only. Every
/// indicator that needs more sessions than the symbol has is nil rather than a
/// short-window approximation — a 12-session "200-day average" would read as
/// real and be wrong.
struct TechnicalSignalsResponse: Content, Equatable {
    let symbol: String
    /// Date of the last candle (`yyyy-MM-dd`).
    let asOf: String
    let close: Double
    let sma50: Double?
    let sma200: Double?
    let trend: TechnicalTrend
    let cross: TechnicalCross
    let rsi14: Double?
    let macd: TechnicalMACD?
    let fiftyTwoWeek: TechnicalFiftyTwoWeek
}

enum TechnicalSignalsConfig {
    /// Trailing sessions fed to the calculation. Covers the 200-day average
    /// plus the cross window plus the 52-week range, with slack to spare.
    static let maxTrailingSessions = 300
    static let fiftyTwoWeekSessions = 252
    /// A flip older than this is history, not a signal.
    static let crossLookbackSessions = 10
    /// Calendar days of history requested upstream. `maxTrailingSessions`
    /// trading days span roughly 430 calendar days; the surplus absorbs
    /// holidays and halts.
    static let historyLookbackDays = 600

    static func redisKey(_ symbol: String) -> String {
        "market:technicals:\(symbol)"
    }

    static func ttlSecondsFromEnvironment() -> Int {
        let ttl = Environment.get("MARKET_TTL_TECHNICALS_SECONDS").flatMap(Int.init(_:)) ?? 3600
        return max(60, ttl)
    }

    /// `from` for the upstream history call, as `yyyy-MM-dd`. The providers
    /// default to one year, which is too thin for a 200-day average plus a
    /// cross window, so the range is always requested explicitly.
    static func historyStart(relativeTo now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let start = calendar.date(byAdding: .day, value: -historyLookbackDays, to: now) ?? now

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)
    }
}

// MARK: - Calculation

enum TechnicalSignals {
    private static let smaFastPeriod = 50
    private static let smaSlowPeriod = 200
    private static let rsiPeriod = 14
    private static let macdFastPeriod = 12
    private static let macdSlowPeriod = 26
    private static let macdSignalPeriod = 9

    /// Returns nil only when there are no candles at all: without one there is
    /// no close and no as-of date to report.
    ///
    /// Candles may arrive in either order — `history` is ascending, the
    /// `StockHistory` shape is descending — so they are ordered here rather
    /// than trusted.
    static func compute(symbol: String, bars: [PriceBarResponse]) -> TechnicalSignalsResponse? {
        let window = Array(
            bars
                .sorted { $0.date < $1.date }
                .suffix(TechnicalSignalsConfig.maxTrailingSessions)
        )
        guard let last = window.last else { return nil }

        let closes = window.map(\.close)
        let fast = movingAverageSeries(closes, period: smaFastPeriod)
        let slow = movingAverageSeries(closes, period: smaSlowPeriod)

        return TechnicalSignalsResponse(
            symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            asOf: last.date,
            close: last.close,
            sma50: fast.last ?? nil,
            sma200: slow.last ?? nil,
            trend: trend(close: last.close, sma50: fast.last ?? nil, sma200: slow.last ?? nil),
            cross: cross(fast: fast, slow: slow),
            rsi14: wilderRSI(closes, period: rsiPeriod),
            macd: macd(closes),
            fiftyTwoWeek: fiftyTwoWeek(window: window, close: last.close)
        )
    }

    // MARK: Moving averages

    /// Simple moving average aligned to `values`: nil until `period` values are
    /// available.
    static func movingAverageSeries(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0 else { return Array(repeating: nil, count: values.count) }

        var series = [Double?](repeating: nil, count: values.count)
        var running = 0.0
        for (index, value) in values.enumerated() {
            running += value
            if index >= period {
                running -= values[index - period]
            }
            if index >= period - 1 {
                series[index] = running / Double(period)
            }
        }
        return series
    }

    /// Exponential moving average seeded with the simple average of the first
    /// `period` values, which is the seeding every MACD reference uses.
    static func exponentialMovingAverageSeries(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }

        var series = [Double?](repeating: nil, count: values.count)
        var previous = values[0 ..< period].reduce(0, +) / Double(period)
        series[period - 1] = previous

        let multiplier = 2.0 / (Double(period) + 1.0)
        for index in period ..< values.count {
            previous = (values[index] - previous) * multiplier + previous
            series[index] = previous
        }
        return series
    }

    private static func trend(close: Double, sma50: Double?, sma200: Double?) -> TechnicalTrend {
        guard let sma50, let sma200 else { return .mixed }
        if close > sma50, close > sma200 {
            return .aboveBoth
        }
        if close < sma50, close < sma200 {
            return .belowBoth
        }
        return .mixed
    }

    /// The most recent session in the cross window where `fast - slow` changed
    /// sign. Sessions where either average is unavailable cannot flip.
    private static func cross(fast: [Double?], slow: [Double?]) -> TechnicalCross {
        let spreads: [Double?] = zip(fast, slow).map { fast, slow in
            guard let fast, let slow else { return nil }
            return fast - slow
        }
        guard spreads.count >= 2 else { return .none }

        let oldest = max(1, spreads.count - TechnicalSignalsConfig.crossLookbackSessions)
        for index in stride(from: spreads.count - 1, through: oldest, by: -1) {
            guard let current = spreads[index], let previous = spreads[index - 1] else { continue }
            if previous <= 0, current > 0 {
                return .goldenCross
            }
            if previous > 0, current <= 0 {
                return .deathCross
            }
        }
        return .none
    }

    // MARK: RSI

    /// Wilder's RSI: the first average is a simple mean of `period` changes,
    /// every later one smooths with weight `(period - 1) / period`.
    static func wilderRSI(_ closes: [Double], period: Int) -> Double? {
        guard period > 0, closes.count > period else { return nil }

        var gains: [Double] = []
        var losses: [Double] = []
        gains.reserveCapacity(closes.count - 1)
        losses.reserveCapacity(closes.count - 1)
        for (previous, current) in zip(closes, closes.dropFirst()) {
            let change = current - previous
            gains.append(max(change, 0))
            losses.append(max(-change, 0))
        }

        var averageGain = gains[0 ..< period].reduce(0, +) / Double(period)
        var averageLoss = losses[0 ..< period].reduce(0, +) / Double(period)
        let weight = Double(period - 1)
        for index in period ..< gains.count {
            averageGain = (averageGain * weight + gains[index]) / Double(period)
            averageLoss = (averageLoss * weight + losses[index]) / Double(period)
        }

        guard averageLoss > 0 else { return averageGain > 0 ? 100 : 50 }
        let strength = averageGain / averageLoss
        return 100 - 100 / (1 + strength)
    }

    // MARK: MACD

    private static func macd(_ closes: [Double]) -> TechnicalMACD? {
        let fast = exponentialMovingAverageSeries(closes, period: macdFastPeriod)
        let slow = exponentialMovingAverageSeries(closes, period: macdSlowPeriod)
        let lines: [Double] = zip(fast, slow).compactMap { fast, slow in
            guard let fast, let slow else { return nil }
            return fast - slow
        }

        guard
            lines.count >= macdSignalPeriod,
            let line = lines.last,
            let signal = exponentialMovingAverageSeries(lines, period: macdSignalPeriod).last ?? nil
        else { return nil }

        let histogram = line - signal
        return TechnicalMACD(
            line: line,
            signal: signal,
            histogram: histogram,
            sign: histogram >= 0 ? .positive : .negative
        )
    }

    // MARK: 52-week range

    private static func fiftyTwoWeek(
        window: [PriceBarResponse],
        close: Double
    ) -> TechnicalFiftyTwoWeek {
        let year = window.suffix(TechnicalSignalsConfig.fiftyTwoWeekSessions)
        let high = year.map(\.high).max() ?? close
        let low = year.map(\.low).min() ?? close

        // A flat window carries no position information, so report the midpoint
        // rather than pick one of the two ends it is simultaneously sitting on.
        let positionPct = high > low
            ? min(100, max(0, (close - low) / (high - low) * 100))
            : 50

        return TechnicalFiftyTwoWeek(high: high, low: low, positionPct: positionPct)
    }
}
