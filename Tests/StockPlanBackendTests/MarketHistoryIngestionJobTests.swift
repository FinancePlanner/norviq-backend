import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market history ingestion")
struct MarketHistoryIngestionJobTests {
    @Test("FMP light history maps to canonical price bars")
    func mapsFMPLightHistory() {
        let bars = MarketHistoryIngestionJob.priceBars(from: [
            CryptoHistoricalLightPoint(
                symbol: "AMD",
                date: "2026-07-16",
                price: 123.45,
                volume: 9876
            ),
        ])

        #expect(bars == [
            PriceBarResponse(
                date: "2026-07-16",
                open: 123.45,
                high: 123.45,
                low: 123.45,
                close: 123.45,
                volume: 9876
            ),
        ])
    }

    @Test("A symbol with stored bars fetches only the days after the last one")
    func incrementalStartAfterLastBar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let fallback = try #require(calendar.date(from: DateComponents(year: 1996, month: 10, day: 9)))
        let last = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7)))

        let start = MarketHistoryIngestionJob.fetchStart(lastDate: last, fallbackStart: fallback, calendar: calendar)

        #expect(start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
    }

    @Test("Only a symbol with no stored bars gets the full backfill")
    func fullBackfillWithoutBars() throws {
        let calendar = Calendar(identifier: .gregorian)
        let fallback = try #require(calendar.date(from: DateComponents(year: 1996, month: 10, day: 9)))

        #expect(MarketHistoryIngestionJob.fetchStart(lastDate: nil, fallbackStart: fallback, calendar: calendar) == fallback)
    }
}
