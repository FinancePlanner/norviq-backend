import Foundation
import StockPlanShared
import Vapor

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

/// CPI release dates published in BLS's official iCalendar feed. The embedded
/// dates are only a continuity fallback for a temporary BLS outage.
enum BLSCPIReleaseCalendar {
    static let calendarURL = URI(string: "https://www.bls.gov/schedule/news_release/bls.ics")

    static let releaseDates2026: [String] = [
        "2026-01-13", "2026-02-13", "2026-03-11", "2026-04-10",
        "2026-05-12", "2026-06-10", "2026-07-14", "2026-08-12",
        "2026-09-11", "2026-10-14", "2026-11-10", "2026-12-10",
    ]

    static func nextPrint(after date: Date, lastOfficial: Double?, on req: Request) async -> NextPrintDTO? {
        do {
            let response = try await req.client.get(calendarURL) { request in
                request.headers.replaceOrAdd(name: .accept, value: "text/calendar")
                request.headers.replaceOrAdd(
                    name: .userAgent,
                    value: "Mozilla/5.0 (compatible; NorviqMacro/1.0; +https://norviq.org)"
                )
                request.timeout = .seconds(10)
            }
            guard response.status == .ok, let body = response.body else {
                throw Abort(.badGateway, reason: "BLS calendar returned HTTP \(response.status.code).")
            }
            let releases = releaseDates(from: body.getString(at: 0, length: body.readableBytes) ?? "")
            if let next = nextPrint(after: date, lastOfficial: lastOfficial, releases: releases) {
                return next
            }
            req.logger.warning("macro_bls_calendar_empty_or_expired using_embedded_fallback=true")
        } catch {
            req.logger.warning("macro_bls_calendar_failed using_embedded_fallback=true error=\(error)")
        }
        return nextPrint(after: date, lastOfficial: lastOfficial)
    }

    /// Extracts CPI event dates from an RFC 5545 calendar. BLS uses both plain
    /// DTSTART and timezone-qualified DTSTART properties, so the parser reads
    /// the property value rather than relying on one exact line shape.
    static func releaseDates(from calendar: String) -> [String] {
        let unfolded = calendar.replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\n ", with: "")
        return unfolded.components(separatedBy: "BEGIN:VEVENT")
            .dropFirst()
            .compactMap { event -> String? in
                guard event.localizedCaseInsensitiveContains("SUMMARY:Consumer Price Index") else { return nil }
                guard let line = event.split(whereSeparator: \Character.isNewline).first(where: {
                    $0.uppercased().hasPrefix("DTSTART")
                }), let separator = line.firstIndex(of: ":") else { return nil }
                let raw = line[line.index(after: separator)...]
                guard raw.count >= 8 else { return nil }
                let compact = String(raw.prefix(8))
                guard compact.allSatisfy(\.isNumber) else { return nil }
                return "\(compact.prefix(4))-\(compact.dropFirst(4).prefix(2))-\(compact.dropFirst(6).prefix(2))"
            }
            .sorted()
    }

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
