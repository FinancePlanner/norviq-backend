import Fluent
import Foundation
import StockPlanShared
import Vapor

/// The windows the performance endpoint can be asked for.
enum PortfolioPerformanceRange: String, CaseIterable, Sendable {
    case oneWeek = "1W"
    case oneMonth = "1M"
    case threeMonths = "3M"
    case oneYear = "1Y"
    case all = "ALL"

    static let `default` = PortfolioPerformanceRange.oneMonth

    init(query: String?) {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              let parsed = PortfolioPerformanceRange(rawValue: query)
        else {
            self = .default
            return
        }
        self = parsed
    }

    /// Days back from today, or nil for everything stored.
    var dayWindow: Int? {
        switch self {
        case .oneWeek: 7
        case .oneMonth: 30
        case .threeMonths: 90
        case .oneYear: 365
        case .all: nil
        }
    }
}

/// Turns stored daily snapshots into the performance response.
///
/// Every number it produces is traceable to an observed or explicitly
/// reconstructed row. Where there is not enough history to answer a question,
/// the answer is omitted rather than defaulted — an absent change tells a client
/// to render an empty state, whereas a zero would assert the portfolio was flat
/// over a window nobody measured.
struct PortfolioPerformanceBuilder: Sendable {
    /// One day of the portfolio's history, after summing across portfolio lists.
    struct Day: Sendable, Equatable {
        let date: Date
        let totalValue: Double
        let costBasis: Double
        let isBackfilled: Bool
    }

    // MARK: - Loading

    /// Snapshots for the given lists, summed per day.
    ///
    /// A day is only included when every list that was recording at the time has
    /// a row for it. Summing a day where one of three portfolios is missing
    /// would under-report the total and draw a dip that never happened — the
    /// same partial-data failure the capture job refuses at the row level, which
    /// has to be refused again here at the aggregate level.
    static func days(
        from snapshots: [PortfolioValueSnapshot],
        listIds: [UUID]
    ) -> [Day] {
        guard !snapshots.isEmpty else { return [] }

        let sorted = snapshots.sorted { $0.capturedOn < $1.capturedOn }
        var byDay: [Date: [UUID: PortfolioValueSnapshot]] = [:]
        var spanByList: [UUID: (first: Date, last: Date)] = [:]

        for snapshot in sorted {
            let day = PortfolioSnapshotValuator.startOfDay(snapshot.capturedOn)
            let listId = snapshot.portfolioListId
            byDay[day, default: [:]][listId] = snapshot
            if let span = spanByList[listId] {
                spanByList[listId] = (min(span.first, day), max(span.last, day))
            } else {
                spanByList[listId] = (day, day)
            }
        }

        let relevant = Set(listIds).intersection(spanByList.keys)

        return byDay.keys.sorted().compactMap { day -> Day? in
            let rows = byDay[day] ?? [:]
            // Every list that had started recording by this day must have a row
            // for it. Summing without one would under-report the total and draw
            // a dip that never happened.
            //
            // Trailing gaps are the hard case, and they are deliberately treated
            // as failures rather than as the portfolio having stopped: once a
            // list has any history, a day missing its row is dropped. A
            // portfolio that was emptied and one whose capture failed look
            // identical here — neither writes a row — so this errs toward
            // showing nothing over showing a number that is silently low, the
            // same direction taken everywhere else in this feature.
            //
            // The cost is that a portfolio emptied but not archived stops the
            // series advancing until it is archived, at which point it leaves
            // `listIds` and drops out of the aggregate entirely.
            let expected = relevant.filter { listId in
                guard let span = spanByList[listId] else { return false }
                return span.first <= day
            }
            guard !expected.isEmpty, expected.allSatisfy({ rows[$0] != nil }) else {
                return nil
            }

            let present = expected.compactMap { rows[$0] }
            return Day(
                date: day,
                totalValue: round2(present.reduce(0) { $0 + $1.totalValue }),
                costBasis: round2(present.reduce(0) { $0 + $1.costBasis }),
                isBackfilled: present.contains {
                    $0.source == PortfolioValueSnapshot.Source.backfill.rawValue
                }
            )
        }
    }

    // MARK: - Changes

    /// Every change the endpoint can compute from `days`.
    ///
    /// `days` must be the full stored history, not a range-filtered slice: a
    /// one-week chart still reports a year-to-date change, and computing it from
    /// a seven-day window would silently answer a different question.
    static func changes(from days: [Day], asOf: Date) -> PortfolioChanges? {
        guard days.count >= 2, let latest = days.last else { return nil }

        let changes = PortfolioChanges(
            day: change(
                to: latest,
                from: days.dropLast().last,
                basis: PortfolioChange.Basis.previousTradingDay
            ),
            week: change(
                to: latest,
                from: baseline(in: days, onOrBefore: addDays(latest.date, -7)),
                basis: PortfolioChange.Basis.week
            ),
            month: change(
                to: latest,
                from: baseline(in: days, onOrBefore: addDays(latest.date, -30)),
                basis: PortfolioChange.Basis.month
            ),
            ytd: change(
                to: latest,
                from: baseline(in: days, onOrBefore: startOfYear(asOf))
                    // Nothing before January: the first day of this year's
                    // history is the year's starting point.
                    ?? days.first(where: { $0.date >= startOfYear(asOf) }),
                basis: PortfolioChange.Basis.ytd
            ),
            sinceInception: change(
                to: latest,
                from: days.first,
                basis: PortfolioChange.Basis.inception
            )
        )

        let isEmpty = changes.day == nil && changes.week == nil && changes.month == nil
            && changes.ytd == nil && changes.sinceInception == nil
        return isEmpty ? nil : changes
    }

    /// The most recent day at or before `target`, or nil when history does not
    /// reach back that far. Returning nil is the point: it is what makes a
    /// missing window render as an empty state instead of as 0.0%.
    private static func baseline(in days: [Day], onOrBefore target: Date) -> Day? {
        days.last { $0.date <= target }
    }

    private static func change(to: Day, from: Day?, basis: String) -> PortfolioChange? {
        guard let from, from.date < to.date, from.totalValue > 0 else { return nil }
        let absolute = to.totalValue - from.totalValue
        return PortfolioChange(
            percent: absolute / from.totalValue,
            absolute: round2(absolute),
            fromDate: formatDay(from.date),
            toDate: formatDay(to.date),
            basis: basis
        )
    }

    // MARK: - Response

    static func response(
        days: [Day],
        range: PortfolioPerformanceRange,
        baseCurrency: String,
        now: Date = Date()
    ) -> PortfolioPerformanceResponse {
        // Changes come from the whole history; only the plotted points are
        // windowed.
        let changes = changes(from: days, asOf: now)

        let windowed: [Day]
        if let window = range.dayWindow {
            let cutoff = addDays(PortfolioSnapshotValuator.startOfDay(now), -window)
            windowed = days.filter { $0.date >= cutoff }
        } else {
            windowed = days
        }

        let points = windowed.map { day in
            PerformancePoint(
                date: formatDay(day.date),
                value: day.totalValue,
                costBasis: day.costBasis,
                source: day.isBackfilled
                    ? PerformancePoint.Source.backfill
                    : PerformancePoint.Source.live
            )
        }

        return PortfolioPerformanceResponse(
            baseCurrency: baseCurrency,
            points: points,
            range: range.rawValue,
            asOf: days.last.map { formatDay($0.date) },
            changes: changes
        )
    }

    // MARK: - Helpers

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func formatDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func addDays(_ date: Date, _ days: Int) -> Date {
        PortfolioSnapshotValuator.addDays(date, days: days)
    }

    private static func startOfYear(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let year = calendar.component(.year, from: date)
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1))
            ?? PortfolioSnapshotValuator.startOfDay(date)
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
