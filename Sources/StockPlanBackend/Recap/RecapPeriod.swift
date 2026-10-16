import Foundation
import StockPlanShared

/// A calendar month or year that a recap covers. Pure value type: all
/// time-zone-dependent answers take the user's zone as an argument.
struct RecapPeriod: Equatable, Sendable {
    let kind: RecapPeriodKind
    let year: Int
    let month: Int?

    /// Parses `("month", "2026-10")` or `("year", "2026")`. Anything else is nil.
    static func parse(kind: String, key: String) -> RecapPeriod? {
        let digits = CharacterSet.decimalDigits
        func isDigits(_ s: Substring, count: Int) -> Bool {
            s.count == count && s.unicodeScalars.allSatisfy { digits.contains($0) }
        }
        switch kind {
        case "month":
            let parts = key.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, isDigits(parts[0], count: 4), isDigits(parts[1], count: 2),
                  let y = Int(parts[0]), let m = Int(parts[1]), (1 ... 12).contains(m)
            else { return nil }
            return RecapPeriod(kind: .month, year: y, month: m)
        case "year":
            guard isDigits(Substring(key), count: 4), let y = Int(key) else { return nil }
            return RecapPeriod(kind: .year, year: y, month: nil)
        default:
            return nil
        }
    }

    var key: String {
        if let month {
            return String(format: "%04d-%02d", year, month)
        }
        return String(format: "%04d", year)
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// Half-open range [start, end), start at local midnight on the 1st.
    func bounds(in timeZone: TimeZone) -> (start: Date, end: Date) {
        let cal = Self.calendar(timeZone)
        let start = cal.date(from: DateComponents(year: year, month: month ?? 1, day: 1))!
        let end = cal.date(from: DateComponents(year: next.year, month: next.month ?? 1, day: 1))!
        return (start, end)
    }

    /// `yyyy-MM-dd` first and last local days, for `GamificationCheckIn.localDate`.
    func localDateRange() -> (first: String, last: String) {
        if let month {
            let cal = Self.calendar(TimeZone(identifier: "UTC")!)
            let first = cal.date(from: DateComponents(year: year, month: month, day: 1))!
            let days = cal.range(of: .day, in: .month, for: first)!.count
            return (
                String(format: "%04d-%02d-01", year, month),
                String(format: "%04d-%02d-%02d", year, month, days)
            )
        }
        return (String(format: "%04d-01-01", year), String(format: "%04d-12-31", year))
    }

    var label: String {
        guard let month else { return String(year) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(formatter.monthSymbols[month - 1]) \(year)"
    }

    var next: RecapPeriod {
        guard let month else { return RecapPeriod(kind: .year, year: year + 1, month: nil) }
        if month == 12 {
            return RecapPeriod(kind: .month, year: year + 1, month: 1)
        }
        return RecapPeriod(kind: .month, year: year, month: month + 1)
    }

    static func lastClosedMonth(now: Date, in timeZone: TimeZone) -> RecapPeriod {
        let c = calendar(timeZone).dateComponents([.year, .month], from: now)
        let y = c.year!, m = c.month!
        return m == 1
            ? RecapPeriod(kind: .month, year: y - 1, month: 12)
            : RecapPeriod(kind: .month, year: y, month: m - 1)
    }

    static func lastClosedYear(now: Date, in timeZone: TimeZone) -> RecapPeriod {
        let y = calendar(timeZone).component(.year, from: now)
        return RecapPeriod(kind: .year, year: y - 1, month: nil)
    }

    /// Available once ended in the user's zone, ending strictly after
    /// `now - 13 months`, and not starting before the user's signup month/year.
    func isAvailable(now: Date, timeZone: TimeZone, userCreatedAt: Date) -> Bool {
        let cal = Self.calendar(timeZone)
        let b = bounds(in: timeZone)
        guard b.end <= now else { return false }
        guard let floor = cal.date(byAdding: .month, value: -13, to: now), b.end > floor else {
            return false
        }
        let c = cal.dateComponents([.year, .month], from: userCreatedAt)
        if let month {
            return (year, month) >= (c.year!, c.month!)
        }
        return year >= c.year!
    }
}
