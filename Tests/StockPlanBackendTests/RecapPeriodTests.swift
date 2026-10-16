import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Recap period")
struct RecapPeriodTests {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func month(_ key: String) -> RecapPeriod {
        RecapPeriod.parse(kind: "month", key: key)!
    }

    @Test("parse accepts valid keys")
    func parseValid() {
        let m = RecapPeriod.parse(kind: "month", key: "2026-10")
        #expect(m?.kind == .month)
        #expect(m?.year == 2026)
        #expect(m?.month == 10)
        #expect(m?.key == "2026-10")
        let y = RecapPeriod.parse(kind: "year", key: "2026")
        #expect(y?.kind == .year)
        #expect(y?.year == 2026)
        #expect(y?.month == nil)
        #expect(y?.key == "2026")
    }

    @Test("parse rejects malformed keys")
    func parseInvalid() {
        #expect(RecapPeriod.parse(kind: "month", key: "2026-13") == nil)
        #expect(RecapPeriod.parse(kind: "month", key: "2026-1") == nil)
        #expect(RecapPeriod.parse(kind: "week", key: "2026-10") == nil)
        #expect(RecapPeriod.parse(kind: "year", key: "26") == nil)
    }

    @Test("bounds respect the time zone")
    func boundsRespectTimeZone() throws {
        let tz = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let b = month("2026-10").bounds(in: tz)
        #expect(b.start == date("2026-10-01T07:00:00Z"))
        #expect(b.end == date("2026-11-01T07:00:00Z"))
    }

    @Test("december rolls the year")
    func decemberRollsYear() throws {
        #expect(month("2026-12").next == month("2027-01"))
        let y = try #require(RecapPeriod.parse(kind: "year", key: "2026"))
        #expect(y.next == RecapPeriod.parse(kind: "year", key: "2027")!)
    }

    @Test("availability")
    func availability() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let created = date("2026-03-10T12:00:00+09:00")
        let now = date("2026-11-01T00:30:00+09:00")
        func ok(_ kind: String, _ key: String) -> Bool {
            RecapPeriod.parse(kind: kind, key: key)!
                .isAvailable(now: now, timeZone: tokyo, userCreatedAt: created)
        }
        #expect(ok("month", "2026-10"))
        #expect(!ok("month", "2026-11"))
        #expect(!ok("month", "2026-02"))
        #expect(!ok("month", "2025-09"))
        #expect(!ok("year", "2026"))
    }

    @Test("availability 13-month lower bound is strict")
    func availabilityThirteenMonths() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let created = date("2024-01-01T12:00:00+09:00")
        let now = date("2026-11-01T00:30:00+09:00")
        func ok(_ key: String) -> Bool {
            month(key).isAvailable(now: now, timeZone: tokyo, userCreatedAt: created)
        }
        #expect(!ok("2025-09"))
        #expect(ok("2025-10"))
    }

    @Test("last closed month and year")
    func lastClosed() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let now = date("2026-11-01T00:30:00+09:00")
        #expect(RecapPeriod.lastClosedMonth(now: now, in: tokyo) == month("2026-10"))
        #expect(RecapPeriod.lastClosedYear(now: now, in: tokyo) == RecapPeriod.parse(kind: "year", key: "2025")!)
        let jan = date("2027-01-02T10:00:00+09:00")
        #expect(RecapPeriod.lastClosedMonth(now: jan, in: tokyo) == month("2026-12"))
    }

    @Test("localDateRange and label")
    func localDateRangeAndLabel() throws {
        let r = month("2026-02").localDateRange()
        #expect(r.first == "2026-02-01")
        #expect(r.last == "2026-02-28")
        let y = try #require(RecapPeriod.parse(kind: "year", key: "2026")?.localDateRange())
        #expect(y.first == "2026-01-01")
        #expect(y.last == "2026-12-31")
        #expect(month("2026-10").label == "October 2026")
        #expect(RecapPeriod.parse(kind: "year", key: "2026")?.label == "2026")
    }
}
