import Foundation
import StockPlanShared

/// 2026 FOMC meeting dates. Source: federalreserve.gov meeting calendar —
/// refresh this table annually alongside the BLS calendar below.
enum FOMCCalendar {
    struct Meeting: Equatable {
        let startDate: String // yyyy-MM-dd
        let endDate: String
    }

    static let meetings2026: [Meeting] = [
        Meeting(startDate: "2026-01-27", endDate: "2026-01-28"),
        Meeting(startDate: "2026-03-17", endDate: "2026-03-18"),
        Meeting(startDate: "2026-04-28", endDate: "2026-04-29"),
        Meeting(startDate: "2026-06-16", endDate: "2026-06-17"),
        Meeting(startDate: "2026-07-28", endDate: "2026-07-29"),
        Meeting(startDate: "2026-09-15", endDate: "2026-09-16"),
        Meeting(startDate: "2026-10-27", endDate: "2026-10-28"),
        Meeting(startDate: "2026-12-08", endDate: "2026-12-09"),
    ]

    static func nextMeeting(after date: Date, calendar meetings: [Meeting] = meetings2026) -> FOMCMeetingDTO? {
        let formatter = Self.dayFormatter
        let today = formatter.string(from: date)
        guard let next = meetings.first(where: { $0.endDate >= today }) else { return nil }
        guard let start = formatter.date(from: next.startDate) else { return nil }
        let days = max(0, Int(start.timeIntervalSince(date) / 86400))
        return FOMCMeetingDTO(
            startDate: next.startDate,
            endDate: next.endDate,
            daysRemaining: days,
            hasPressConference: true,
            odds: nil // No free FedWatch/odds API — documented gap.
        )
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// 2026 BLS CPI release dates (8:30 AM ET). Source: bls.gov/schedule —
/// verified against the published schedule; refresh annually.
enum BLSCPIReleaseCalendar {
    static let releaseDates2026: [String] = [
        "2026-01-13", "2026-02-11", "2026-03-11", "2026-04-10",
        "2026-05-12", "2026-06-10", "2026-07-14", "2026-08-12",
        "2026-09-11", "2026-10-13", "2026-11-10", "2026-12-10",
    ]

    static func nextPrint(after date: Date, lastOfficial: Double?, releases: [String] = releaseDates2026) -> NextPrintDTO? {
        let formatter = FOMCCalendar.dayFormatter
        let today = formatter.string(from: date)
        guard let next = releases.first(where: { $0 >= today }),
              let releaseDate = formatter.date(from: next)
        else { return nil }
        let days = max(0, Int(releaseDate.timeIntervalSince(date) / 86400))
        return NextPrintDTO(
            date: next,
            daysRemaining: days,
            forecastNowflation: nil, // filled by Nowflation enrichment when configured
            streetConsensus: nil,
            lastOfficial: lastOfficial
        )
    }
}
