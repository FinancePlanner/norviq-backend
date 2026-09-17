import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Earnings beat/miss streak")
struct EarningsStreakTests {
    // MARK: - Fixtures

    /// One quarter, dated by index: index 0 is the newest.
    private func quarter(_ index: Int, actual: Double?, estimate: Double?) -> EarningsResponse {
        EarningsResponse(
            symbol: "AAPL",
            date: String(format: "20%02d-01-15", 25 - index),
            epsActual: actual,
            epsEstimated: estimate,
            revenueActual: nil,
            revenueEstimated: nil,
            lastUpdated: nil,
            surprisePercent: nil,
            hasTranscript: false
        )
    }

    /// Newest first: three beats, then a miss, then two beats.
    private var threeBeatsThenAMiss: [EarningsResponse] {
        [
            quarter(0, actual: 1.20, estimate: 1.00),
            quarter(1, actual: 1.10, estimate: 1.00),
            quarter(2, actual: 1.00, estimate: 1.00),
            quarter(3, actual: 0.80, estimate: 1.00),
            quarter(4, actual: 1.30, estimate: 1.00),
            quarter(5, actual: 1.40, estimate: 1.00),
        ]
    }

    /// Newest first: three misses, then a beat, then two misses.
    private var threeMissesThenABeat: [EarningsResponse] {
        [
            quarter(0, actual: 0.80, estimate: 1.00),
            quarter(1, actual: 0.90, estimate: 1.00),
            quarter(2, actual: 0.95, estimate: 1.00),
            quarter(3, actual: 1.20, estimate: 1.00),
            quarter(4, actual: 0.70, estimate: 1.00),
            quarter(5, actual: 0.60, estimate: 1.00),
        ]
    }

    // MARK: - The headline streak

    @Test("Three beats before a miss read as a beat streak of three")
    func threeBeatsReadAsABeatStreak() throws {
        let annotated = EarningsStreak.annotate(threeBeatsThenAMiss)
        let newest = try #require(annotated.first)

        #expect(newest.beatStreak == 3)
        #expect(newest.missStreak == 0)
    }

    @Test("Three misses before a beat read as a miss streak of three")
    func threeMissesReadAsAMissStreak() throws {
        let annotated = EarningsStreak.annotate(threeMissesThenABeat)
        let newest = try #require(annotated.first)

        #expect(newest.missStreak == 3)
        #expect(newest.beatStreak == 0)
    }

    @Test("Meeting the estimate exactly counts as a beat")
    func meetingTheEstimateCountsAsABeat() throws {
        let annotated = EarningsStreak.annotate([quarter(0, actual: 1.00, estimate: 1.00)])
        let newest = try #require(annotated.first)

        #expect(newest.beatStreak == 1)
        #expect(newest.missStreak == 0)
    }

    // MARK: - Unreported quarters

    @Test("A scheduled quarter with no actual carries no streak of its own")
    func unreportedNewestQuarterCarriesNoStreak() throws {
        let scheduled = [quarter(-1, actual: nil, estimate: 1.00)] + threeBeatsThenAMiss
        let annotated = EarningsStreak.annotate(scheduled)
        let newest = try #require(annotated.first)

        #expect(newest.beatStreak == 0)
        #expect(newest.missStreak == 0)
        // The last *reported* quarter below it still carries the streak, which is
        // what a caller reads once it skips the scheduled row.
        #expect(annotated[1].beatStreak == 3)
        #expect(annotated[1].missStreak == 0)
    }

    @Test("A quarter with no estimate ends the streak beneath it")
    func missingEstimateEndsTheStreak() {
        let quarters = [
            quarter(0, actual: 1.20, estimate: 1.00),
            quarter(1, actual: 1.10, estimate: nil),
            quarter(2, actual: 1.05, estimate: 1.00),
        ]
        let annotated = EarningsStreak.annotate(quarters)

        #expect(annotated[0].beatStreak == 1)
        #expect(annotated[1].beatStreak == 0)
        #expect(annotated[1].missStreak == 0)
        #expect(annotated[2].beatStreak == 1)
    }

    @Test("No quarters at all yields no quarters at all")
    func emptyInputYieldsEmptyOutput() {
        #expect(EarningsStreak.annotate([]).isEmpty)
    }

    // MARK: - Per-quarter values and ordering

    @Test("Each quarter carries the run that ends at it")
    func eachQuarterCarriesItsOwnRun() {
        let annotated = EarningsStreak.annotate(threeBeatsThenAMiss)

        #expect(annotated.map(\.beatStreak) == [3, 2, 1, 0, 2, 1])
        #expect(annotated.map(\.missStreak) == [0, 0, 0, 1, 0, 0])
    }

    @Test("Quarters arriving oldest-first get the same streaks, in their own order")
    func inputOrderDoesNotChangeTheStreaks() throws {
        let ascending = Array(threeBeatsThenAMiss.reversed())
        let annotated = EarningsStreak.annotate(ascending)

        // Each quarter keeps the streak it had, and the response keeps the order
        // it arrived in.
        #expect(annotated.map(\.date) == ascending.map(\.date))
        #expect(annotated.map(\.beatStreak) == [1, 2, 0, 1, 2, 3])

        let newest = try #require(annotated.last)
        #expect(newest.beatStreak == 3)
    }
}
