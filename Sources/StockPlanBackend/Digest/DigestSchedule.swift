import Foundation

/// When a user's digest is due, and which week it covers. Pure, so DST and
/// zone edge cases are unit-tested without a database.
///
/// A digest is due on the user's chosen ISO weekday once their local hour has
/// passed, and stays due for `maxLateness` after that. Past the window it is
/// simply not sent that week: a Sunday digest arriving on Monday after an
/// outage would describe a stale week.
enum DigestSchedule {
    struct Period: Hashable, Sendable {
        /// `yyyy-MM-dd`, inclusive: six days before `end`.
        let start: String
        /// `yyyy-MM-dd`, inclusive: the send day.
        let end: String
    }

    static let maxLateness: TimeInterval = 6 * 3600

    static func duePeriod(now: Date, timeZone: TimeZone, weekday: Int, localHour: Int) -> Period? {
        let calendar = calendar(in: timeZone)
        let parts = calendar.dateComponents([.weekday, .hour], from: now)
        guard let calendarWeekday = parts.weekday, let hour = parts.hour else { return nil }
        guard isoWeekday(fromCalendarWeekday: calendarWeekday) == weekday, hour >= localHour else { return nil }
        guard let sendAt = calendar.date(bySettingHour: localHour, minute: 0, second: 0, of: now),
              now.timeIntervalSince(sendAt) <= maxLateness
        else { return nil }
        return period(endingOn: now, timeZone: timeZone)
    }

    /// The seven local days ending on `date`'s local day.
    static func period(endingOn date: Date, timeZone: TimeZone) -> Period {
        let calendar = calendar(in: timeZone)
        let endDay = calendar.startOfDay(for: date)
        let startDay = calendar.date(byAdding: .day, value: -6, to: endDay) ?? endDay
        return Period(start: localDate(startDay, calendar: calendar), end: localDate(endDay, calendar: calendar))
    }

    /// Calendar weekday is 1 = Sunday … 7 = Saturday; ISO is 1 = Monday … 7 = Sunday.
    static func isoWeekday(fromCalendarWeekday weekday: Int) -> Int {
        weekday == 1 ? 7 : weekday - 1
    }

    /// Shifts a `yyyy-MM-dd` string by whole days. Calendar arithmetic in UTC,
    /// so no zone can make a day 23 or 25 hours long.
    static func shift(_ day: String, byDays days: Int) -> String? {
        let utc = calendar(in: TimeZone(identifier: "UTC")!)
        guard let date = parseDay(day),
              let shifted = utc.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return localDate(shifted, calendar: utc)
    }

    static func parseDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let utc = calendar(in: TimeZone(identifier: "UTC")!)
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func localDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
