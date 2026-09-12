import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

/// Tests for turning stored snapshots into the performance response.
///
/// The property under test throughout is that an unanswerable question is left
/// unanswered. A change the data cannot support must be absent, because a zero
/// would assert the portfolio was flat over a window nobody measured — which is
/// the same lie, in a new costume, as the random series this replaced.
@Suite("PortfolioPerformanceBuilder")
struct PortfolioPerformanceBuilderTests {
    /// 2024-03-15T00:00:00Z.
    private static let day0 = Date(timeIntervalSince1970: 1_710_460_800)

    private static func day(_ offset: Int) -> Date {
        PortfolioSnapshotValuator.addDays(day0, days: offset)
    }

    private func makeDay(
        _ offset: Int,
        value: Double,
        costBasis: Double = 1000,
        backfilled: Bool = false
    ) -> PortfolioPerformanceBuilder.Day {
        PortfolioPerformanceBuilder.Day(
            date: Self.day(offset),
            totalValue: value,
            costBasis: costBasis,
            isBackfilled: backfilled
        )
    }

    private func makeSnapshot(
        userId: UUID = UUID(),
        listId: UUID,
        dayOffset: Int,
        marketValue: Double,
        cash: Double = 0,
        source: PortfolioValueSnapshot.Source = .live
    ) -> PortfolioValueSnapshot {
        PortfolioValueSnapshot(
            userId: userId,
            portfolioListId: listId,
            capturedOn: Self.day(dayOffset),
            currency: "USD",
            marketValue: marketValue,
            costBasis: 1000,
            cashBalance: cash,
            positionCount: 1,
            source: source,
            pricedSymbols: 1,
            missingSymbols: 0
        )
    }

    // MARK: - Absent, not zero

    /// With a single recorded day there is nothing to compare against. Every
    /// change must be absent — this is the state a brand new account is in, and
    /// the one where a defaulted 0.0% would be most misleading.
    @Test("A single day yields no changes at all")
    func singleDayHasNoChanges() {
        let changes = PortfolioPerformanceBuilder.changes(
            from: [makeDay(0, value: 1000)],
            asOf: Self.day(0)
        )

        #expect(changes == nil)
    }

    @Test("No history yields no changes")
    func noHistoryHasNoChanges() {
        #expect(PortfolioPerformanceBuilder.changes(from: [], asOf: Self.day(0)) == nil)
    }

    /// Two days of history can answer "versus the previous trading day" and
    /// "since inception". It cannot answer "versus a month ago", and must say so
    /// by omission rather than by reporting zero.
    @Test("Windows longer than the recorded history are omitted, not zeroed")
    func longWindowsAreOmitted() throws {
        let days = [makeDay(-1, value: 1000), makeDay(0, value: 996)]

        let changes = try #require(
            PortfolioPerformanceBuilder.changes(from: days, asOf: Self.day(0))
        )

        #expect(changes.day != nil)
        #expect(changes.sinceInception != nil)
        #expect(changes.week == nil, "two days cannot answer a weekly change")
        #expect(changes.month == nil, "two days cannot answer a monthly change")
    }

    // MARK: - The number itself

    /// The reported figure must be the real move between two recorded days, and
    /// must be identical on every call — the defect being fixed was a value that
    /// changed on each page load.
    @Test("The day change is the real move between the last two recorded days")
    func dayChangeIsReal() throws {
        let days = [makeDay(-1, value: 1000), makeDay(0, value: 996)]

        let changes = try #require(
            PortfolioPerformanceBuilder.changes(from: days, asOf: Self.day(0))
        )
        let dayChange = try #require(changes.day)

        #expect(abs(dayChange.percent - -0.004) < 0.000_001)
        #expect(dayChange.absolute == -4)
        #expect(dayChange.basis == PortfolioChange.Basis.previousTradingDay)
        #expect(dayChange.fromDate == "2024-03-14")
        #expect(dayChange.toDate == "2024-03-15")

        // Deterministic: same input, same answer, every time.
        let again = try #require(
            PortfolioPerformanceBuilder.changes(from: days, asOf: Self.day(0))
        )
        #expect(again.day == dayChange)
    }

    /// "Previous trading day", not "yesterday". A gap over a closed market is
    /// exactly why the label had to change.
    @Test("The day change compares recorded days, skipping closed ones")
    func dayChangeSkipsClosedDays() throws {
        // Friday then Monday: the weekend has no rows.
        let days = [makeDay(0, value: 1000), makeDay(3, value: 1100)]

        let changes = try #require(
            PortfolioPerformanceBuilder.changes(from: days, asOf: Self.day(3))
        )
        let dayChange = try #require(changes.day)

        #expect(dayChange.fromDate == "2024-03-15")
        #expect(dayChange.toDate == "2024-03-18")
        #expect(abs(dayChange.percent - 0.1) < 0.000_001)
    }

    @Test("A weekly change uses the last recorded day at or before the cutoff")
    func weeklyChangeUsesNearestEarlierDay() throws {
        let days = [
            makeDay(-10, value: 900),
            makeDay(-8, value: 950),
            makeDay(-3, value: 1050),
            makeDay(0, value: 1000),
        ]

        let changes = try #require(
            PortfolioPerformanceBuilder.changes(from: days, asOf: Self.day(0))
        )
        let week = try #require(changes.week)

        // Cutoff is day -7; the nearest recorded day at or before it is -8.
        #expect(week.fromDate == "2024-03-07")
        #expect(week.toDate == "2024-03-15")
        #expect(abs(week.percent - (1000.0 - 950) / 950) < 0.000_001)
    }

    @Test("Since-inception compares against the earliest recorded day")
    func sinceInceptionUsesEarliestDay() throws {
        let days = [
            makeDay(-30, value: 500),
            makeDay(-10, value: 800),
            makeDay(0, value: 1000),
        ]

        let changes = try #require(
            PortfolioPerformanceBuilder.changes(from: days, asOf: Self.day(0))
        )
        let inception = try #require(changes.sinceInception)

        #expect(inception.fromDate == "2024-02-14")
        #expect(abs(inception.percent - 1.0) < 0.000_001)
        #expect(inception.absolute == 500)
    }

    /// A zero baseline cannot yield a percentage. Omitting beats dividing by zero
    /// or inventing an infinite gain.
    @Test("A zero starting value omits the change")
    func zeroBaselineOmitsChange() {
        let days = [makeDay(-1, value: 0), makeDay(0, value: 1000)]

        let changes = PortfolioPerformanceBuilder.changes(from: days, asOf: Self.day(0))

        #expect(changes?.day == nil)
    }

    // MARK: - Aggregating portfolios

    @Test("Values are summed across portfolio lists for a day")
    func sumsAcrossLists() throws {
        let userId = UUID()
        let first = UUID()
        let second = UUID()
        let snapshots = [
            makeSnapshot(userId: userId, listId: first, dayOffset: 0, marketValue: 1000, cash: 100),
            makeSnapshot(userId: userId, listId: second, dayOffset: 0, marketValue: 500),
        ]

        let days = PortfolioPerformanceBuilder.days(from: snapshots, listIds: [first, second])

        #expect(days.count == 1)
        #expect(try #require(days.first).totalValue == 1600)
    }

    /// The aggregate-level version of the rule the capture job enforces per row.
    /// Summing a day where one of two portfolios has no row would under-report
    /// the total and draw a dip that never happened.
    @Test("A day missing one portfolio's row is dropped, not summed short")
    func dropsDaysWithAMissingPortfolio() throws {
        let userId = UUID()
        let first = UUID()
        let second = UUID()
        let snapshots = [
            // Both present on day -1.
            makeSnapshot(userId: userId, listId: first, dayOffset: -1, marketValue: 1000),
            makeSnapshot(userId: userId, listId: second, dayOffset: -1, marketValue: 500),
            // Only the first on day 0 — the second failed to capture.
            makeSnapshot(userId: userId, listId: first, dayOffset: 0, marketValue: 1010),
        ]

        let days = PortfolioPerformanceBuilder.days(from: snapshots, listIds: [first, second])

        #expect(days.count == 1)
        #expect(try #require(days.first).totalValue == 1500)
        #expect(days.allSatisfy { $0.totalValue != 1010 }, "must not report a half-portfolio")
    }

    /// A portfolio opened later must not erase the history that predates it.
    @Test("Days before a portfolio existed still count the ones that did")
    func daysBeforeAPortfolioExistedAreKept() throws {
        let userId = UUID()
        let old = UUID()
        let new = UUID()
        let snapshots = [
            makeSnapshot(userId: userId, listId: old, dayOffset: -5, marketValue: 1000),
            makeSnapshot(userId: userId, listId: old, dayOffset: 0, marketValue: 1200),
            // The second portfolio only starts on day 0.
            makeSnapshot(userId: userId, listId: new, dayOffset: 0, marketValue: 300),
        ]

        let days = PortfolioPerformanceBuilder.days(from: snapshots, listIds: [old, new])

        #expect(days.count == 2)
        #expect(try #require(days.first).totalValue == 1000)
        #expect(try #require(days.last).totalValue == 1500)
    }

    /// A trailing gap is treated as a failed capture, not as the portfolio
    /// having stopped: the two are indistinguishable in the data, and dropping
    /// the day shows nothing rather than a total that is silently low.
    ///
    /// The cost, documented here so it is a decision rather than a surprise: a
    /// portfolio emptied but not archived holds the series back until it is
    /// archived, at which point it leaves `listIds` and drops out entirely.
    @Test("A trailing gap is treated as a missing capture, not a stopped portfolio")
    func trailingGapIsTreatedAsMissingCapture() throws {
        let userId = UUID()
        let kept = UUID()
        let stopped = UUID()
        let snapshots = [
            makeSnapshot(userId: userId, listId: kept, dayOffset: -2, marketValue: 1000),
            makeSnapshot(userId: userId, listId: stopped, dayOffset: -2, marketValue: 400),
            makeSnapshot(userId: userId, listId: kept, dayOffset: -1, marketValue: 1010),
        ]

        let days = PortfolioPerformanceBuilder.days(from: snapshots, listIds: [kept, stopped])

        #expect(days.count == 1)
        #expect(try #require(days.first).totalValue == 1400)
    }

    /// Archiving is the supported way for a portfolio to leave the aggregate:
    /// it drops out of `listIds`, and the remaining ones keep reporting.
    @Test("A portfolio outside listIds does not hold the series back")
    func archivedPortfolioDoesNotHoldSeriesBack() throws {
        let userId = UUID()
        let kept = UUID()
        let archived = UUID()
        let snapshots = [
            makeSnapshot(userId: userId, listId: kept, dayOffset: -2, marketValue: 1000),
            makeSnapshot(userId: userId, listId: archived, dayOffset: -2, marketValue: 400),
            makeSnapshot(userId: userId, listId: kept, dayOffset: -1, marketValue: 1010),
            makeSnapshot(userId: userId, listId: kept, dayOffset: 0, marketValue: 1020),
        ]

        // Only the kept list is asked for, as resolveFilter would after archiving.
        let days = PortfolioPerformanceBuilder.days(from: snapshots, listIds: [kept])

        #expect(days.count == 3)
        #expect(try #require(days.last).totalValue == 1020)
    }

    @Test("A day is marked backfilled when any contributing row was reconstructed")
    func marksBackfilledDays() throws {
        let userId = UUID()
        let first = UUID()
        let second = UUID()
        let snapshots = [
            makeSnapshot(userId: userId, listId: first, dayOffset: 0, marketValue: 1000, source: .live),
            makeSnapshot(userId: userId, listId: second, dayOffset: 0, marketValue: 500, source: .backfill),
        ]

        let days = PortfolioPerformanceBuilder.days(from: snapshots, listIds: [first, second])

        #expect(try #require(days.first).isBackfilled)
    }

    // MARK: - Range windowing

    @Test("The range windows the points but not the changes")
    func rangeWindowsPointsOnly() throws {
        let days = (0 ... 60).map { offset in
            makeDay(-60 + offset, value: 1000 + Double(offset))
        }

        let response = PortfolioPerformanceBuilder.response(
            days: days,
            range: .oneWeek,
            baseCurrency: "USD",
            now: Self.day(0)
        )

        // A week of points...
        #expect(response.points.count <= 8)
        #expect(response.range == "1W")

        // ...but the monthly change is still answerable from the full history.
        let changes = try #require(response.changes)
        #expect(changes.month != nil, "a 1W chart must still report a monthly change")
    }

    @Test("ALL returns every recorded point")
    func allRangeReturnsEverything() {
        let days = (0 ... 40).map { offset in makeDay(-40 + offset, value: 1000) }

        let response = PortfolioPerformanceBuilder.response(
            days: days,
            range: .all,
            baseCurrency: "USD",
            now: Self.day(0)
        )

        #expect(response.points.count == 41)
    }

    @Test("An unrecognised range falls back to the default rather than failing")
    func unknownRangeFallsBack() {
        #expect(PortfolioPerformanceRange(query: "banana") == .default)
        #expect(PortfolioPerformanceRange(query: nil) == .default)
        #expect(PortfolioPerformanceRange(query: "1w") == .oneWeek)
        #expect(PortfolioPerformanceRange(query: " 3M ") == .threeMonths)
    }

    // MARK: - Response shape

    @Test("An account with no recorded history gets an empty, honest response")
    func emptyHistoryResponse() {
        let response = PortfolioPerformanceBuilder.response(
            days: [],
            range: .oneMonth,
            baseCurrency: "USD",
            now: Self.day(0)
        )

        #expect(response.points.isEmpty)
        #expect(response.changes == nil)
        #expect(response.asOf == nil)
        #expect(response.baseCurrency == "USD")
    }

    @Test("Points carry their cost basis and provenance")
    func pointsCarryProvenance() throws {
        let days = [
            makeDay(-1, value: 1000, costBasis: 900, backfilled: true),
            makeDay(0, value: 1100, costBasis: 900, backfilled: false),
        ]

        let response = PortfolioPerformanceBuilder.response(
            days: days,
            range: .all,
            baseCurrency: "USD",
            now: Self.day(0)
        )

        let first = try #require(response.points.first)
        #expect(first.costBasis == 900)
        #expect(first.source == PerformancePoint.Source.backfill)

        let last = try #require(response.points.last)
        #expect(last.source == PerformancePoint.Source.live)
        #expect(response.asOf == "2024-03-15")
    }
}
