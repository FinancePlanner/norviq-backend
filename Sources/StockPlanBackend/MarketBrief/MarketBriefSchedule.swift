import Foundation
import StockPlanShared

/// When each brief is due. Pure: the job asks it on every tick.
///
/// Everything is computed in Europe/Lisbon local time, so daylight saving
/// needs no special case: 08:15 Lisbon is 08:15 UTC in winter and 07:15 UTC
/// in summer, and the calendar does that arithmetic.
///
/// Each slot is a window, not an instant, so a pod that boots late (or a
/// tick that fails) still produces the brief on a later tick.
enum MarketBriefSchedule {
    struct Due: Hashable, Sendable {
        /// Lisbon calendar date, `yyyy-MM-dd`.
        let tradingDate: String
        let slot: MarketBriefSlot
    }

    // swiftlint:disable:next force_unwrapping
    static let timeZone = TimeZone(identifier: "Europe/Lisbon")!

    /// Minutes since local midnight. The morning window opens 15 minutes after
    /// the European cash open so the European rows are live, not yesterday's.
    static let morningStart = 8 * 60 + 15
    static let morningEnd = 12 * 60
    static let eveningStart = 22 * 60 + 30
    static let eveningEnd = 24 * 60

    static func dueSlot(now: Date) -> Due? {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = parts.weekday, (2 ... 6).contains(weekday),
              let hour = parts.hour, let minute = parts.minute
        else { return nil }
        let minutes = hour * 60 + minute
        if minutes >= morningStart, minutes < morningEnd {
            return Due(tradingDate: localDate(now), slot: .morning)
        }
        if minutes >= eveningStart, minutes < eveningEnd {
            return Due(tradingDate: localDate(now), slot: .evening)
        }
        return nil
    }

    static func localDate(_ now: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return "\(parts.year ?? 0)-\(pad(parts.month ?? 0))-\(pad(parts.day ?? 0))"
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
