import Foundation
import StockPlanShared
import Vapor

/// FOMC meeting dates. Source: federalreserve.gov meeting calendar —
/// refresh this table annually alongside the BLS calendar below. 2027 copied
/// from https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm on
/// 2026-10-19; the Fed calls each date tentative until the meeting before it.
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

    static let meetings2027: [Meeting] = [
        Meeting(startDate: "2027-01-26", endDate: "2027-01-27"),
        Meeting(startDate: "2027-03-16", endDate: "2027-03-17"),
        Meeting(startDate: "2027-04-27", endDate: "2027-04-28"),
        Meeting(startDate: "2027-06-08", endDate: "2027-06-09"),
        Meeting(startDate: "2027-07-27", endDate: "2027-07-28"),
        Meeting(startDate: "2027-09-14", endDate: "2027-09-15"),
        Meeting(startDate: "2027-10-26", endDate: "2027-10-27"),
        Meeting(startDate: "2027-12-07", endDate: "2027-12-08"),
    ]

    static let meetings = meetings2026 + meetings2027

    static func nextMeeting(after date: Date, calendar meetings: [Meeting] = meetings) -> FOMCMeetingDTO? {
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

    /// Copied from https://www.bls.gov/schedule/news_release/cpi.htm on 2026-10-19.
    static let releaseDates2027: [String] = [
        "2027-01-13", "2027-02-11", "2027-03-10", "2027-04-13",
        "2027-05-12", "2027-06-10", "2027-07-14", "2027-08-11",
        "2027-09-14", "2027-10-14", "2027-11-10", "2027-12-10",
    ]

    static let releaseDates = releaseDates2026 + releaseDates2027

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

    static func nextPrint(after date: Date, lastOfficial: Double?, releases: [String] = releaseDates) -> NextPrintDTO? {
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

/// Release and meeting days outside the US, for the Daily board's week-ahead
/// post. Every date is copied from the official calendar named above its
/// table on 2026-10-19, never projected. A table that has run out yields no
/// row: the post leaves that event out rather than guess.
enum WorldMacroCalendar {
    struct Event: Equatable, Sendable {
        let date: String // yyyy-MM-dd, local to the institution
        let name: String
    }

    /// ECB Governing Council monetary policy decisions (day 2, press
    /// conference). https://www.ecb.europa.eu/press/calendars/mgcgc/html/index.en.html
    static let ecbDecisions = [
        "2026-10-29", "2026-12-17",
        "2027-02-04", "2027-03-18", "2027-04-29", "2027-06-10",
        "2027-07-22", "2027-09-09", "2027-10-28", "2027-12-16",
    ]

    /// Euro-area HICP flash estimate. 2027 not published yet.
    /// https://ec.europa.eu/eurostat/news/release-calendar
    static let hicpFlash = [
        "2026-01-07", "2026-02-04", "2026-03-03", "2026-03-31", "2026-04-30", "2026-06-02",
        "2026-07-01", "2026-07-31", "2026-09-01", "2026-10-02", "2026-11-04", "2026-12-01",
    ]

    /// Bank of Japan Monetary Policy Meeting, last day (the decision).
    /// https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm
    static let bojDecisions = [
        "2026-01-23", "2026-03-19", "2026-04-28", "2026-06-16",
        "2026-07-31", "2026-09-18", "2026-10-30", "2026-12-18",
        "2027-01-22", "2027-03-18", "2027-04-28", "2027-06-11",
        "2027-07-22", "2027-09-22", "2027-10-29", "2027-12-17",
    ]

    /// Japan national CPI. Published through the February 2027 survey month.
    /// https://www.stat.go.jp/english/data/cpi/1582.html
    static let japanCPI = [
        "2026-01-23", "2026-02-20", "2026-03-24", "2026-04-24", "2026-05-22", "2026-06-19",
        "2026-07-24", "2026-08-21", "2026-09-18", "2026-10-23", "2026-11-20", "2026-12-18",
        "2027-01-22", "2027-02-19", "2027-03-19",
    ]

    /// China CPI (NBS). NBS calls the dates preliminary; 2027 not published yet.
    /// https://www.stats.gov.cn/english/PressRelease/ReleaseCalendar/202512/t20251226_1962154.html
    static let chinaCPI = [
        "2026-01-09", "2026-02-11", "2026-03-09", "2026-04-10", "2026-05-11", "2026-06-10",
        "2026-07-09", "2026-08-09", "2026-09-09", "2026-10-14", "2026-11-09", "2026-12-09",
    ]

    /// Every known event from `from` through `through`, both yyyy-MM-dd and
    /// inclusive, US ones included, in date order.
    static func events(from: String, through: String) -> [Event] {
        let tables: [(String, [String])] = [
            ("US CPI release", BLSCPIReleaseCalendar.releaseDates),
            ("Fed rate decision (FOMC)", FOMCCalendar.meetings.map(\.endDate)),
            ("ECB rate decision", ecbDecisions),
            ("Euro-area inflation flash (HICP)", hicpFlash),
            ("Bank of Japan rate decision", bojDecisions),
            ("Japan CPI release", japanCPI),
            ("China CPI release", chinaCPI),
        ]
        return tables
            .flatMap { name, dates in
                dates.filter { $0 >= from && $0 <= through }.map { Event(date: $0, name: name) }
            }
            .sorted { ($0.date, $0.name) < ($1.date, $1.name) }
    }
}
