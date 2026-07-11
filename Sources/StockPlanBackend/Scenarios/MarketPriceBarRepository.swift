import Fluent
import FluentSQL
import Foundation
import StockPlanShared

struct MarketHistoryCoverage: Sendable, Equatable {
    let firstDate: Date?
    let lastDate: Date?
    let barCount: Int
    let missingWeekdays: Int
}

struct MarketPriceBarRepository {
    func adjustedCloses(
        instrumentKey: String, from: Date, to: Date, on database: any Database
    ) async throws -> [(date: Date, close: Double)] {
        guard let sql = database as? any SQLDatabase else { return [] }
        return try await sql.raw("""
        SELECT date, adjusted_close FROM market_price_bars
        WHERE instrument_key = \(bind: instrumentKey.uppercased()) AND date BETWEEN \(bind: from) AND \(bind: to)
        ORDER BY date ASC
        """).all().compactMap { row in
            guard let date = try? row.decode(column: "date", as: Date.self),
                  let close = try? row.decode(column: "adjusted_close", as: Double.self) else { return nil }
            return (date, close)
        }
    }

    func upsert(
        instrumentKey: String,
        currency: String,
        provider: String,
        bars: [PriceBarResponse],
        on database: any Database
    ) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for bar in bars {
            guard let date = Self.dateFormatter.date(from: bar.date) else { continue }
            try await sql.raw("""
            INSERT INTO market_price_bars
                (instrument_key, date, open, high, low, close, adjusted_close, volume, currency, provider)
            VALUES (\(bind: instrumentKey.uppercased()), \(bind: date), \(bind: bar.open), \(bind: bar.high),
                    \(bind: bar.low), \(bind: bar.close), \(bind: bar.close), \(bind: bar.volume.map(Double.init)),
                    \(bind: currency.uppercased()), \(bind: provider))
            ON CONFLICT (instrument_key, date) DO UPDATE SET
                open = EXCLUDED.open, high = EXCLUDED.high, low = EXCLUDED.low,
                close = EXCLUDED.close, adjusted_close = EXCLUDED.adjusted_close,
                volume = EXCLUDED.volume, currency = EXCLUDED.currency,
                provider = EXCLUDED.provider, updated_at = NOW()
            """).run()
        }
    }

    func coverage(instrumentKey: String, from: Date, to: Date, on database: any Database) async throws -> MarketHistoryCoverage {
        guard let sql = database as? any SQLDatabase else { return .init(firstDate: nil, lastDate: nil, barCount: 0, missingWeekdays: 0) }
        let rows = try await sql.raw("""
        SELECT MIN(date) AS first_date, MAX(date) AS last_date, COUNT(*)::INT AS bar_count
        FROM market_price_bars WHERE instrument_key = \(bind: instrumentKey.uppercased())
            AND date BETWEEN \(bind: from) AND \(bind: to)
        """).all()
        let row = rows.first
        let first = try? row?.decode(column: "first_date", as: Date.self)
        let last = try? row?.decode(column: "last_date", as: Date.self)
        let count = (try? row?.decode(column: "bar_count", as: Int.self)) ?? 0
        let expected = Self.weekdays(from: from, to: to)
        return .init(firstDate: first ?? nil, lastDate: last ?? nil, barCount: count, missingWeekdays: max(0, expected - count))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()

    private static func weekdays(from: Date, to: Date) -> Int {
        var date = from; var count = 0; let calendar = Calendar(identifier: .gregorian)
        while date <= to {
            if !calendar.isDateInWeekend(date) {
                count += 1
            }; date = calendar.date(byAdding: .day, value: 1, to: date) ?? to.addingTimeInterval(1)
        }
        return count
    }
}
