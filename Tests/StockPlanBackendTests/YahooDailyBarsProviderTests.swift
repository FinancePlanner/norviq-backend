import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Yahoo daily bars provider")
struct YahooDailyBarsProviderTests {
    /// Closes at 16:00 New York on 2025-10-14, 2025-12-30, 2025-12-31,
    /// 2026-01-02 (null, must be dropped), 2026-10-09 and 2026-10-16.
    private static let json = """
    {"chart":{"result":[{"meta":{"symbol":"SPY","currency":"USD","exchangeTimezoneName":"America/New_York",\
    "regularMarketPrice":660.0,"regularMarketTime":1792180800},\
    "timestamp":[1760472000,1767128400,1767214800,1767387600,1791576000,1792180800],\
    "indicators":{"quote":[{"close":[700.0,600.0,610.0,null,640.0,660.0]}]}}],"error":null}}
    """

    private func series() throws -> DailyBarSeries {
        try #require(try YahooDailyBarsProvider.parse(Data(Self.json.utf8)))
    }

    @Test("Reads closes in exchange time and drops null closes")
    func parsesBars() throws {
        let series = try series()
        #expect(series.symbol == "SPY")
        #expect(series.currency == "USD")
        #expect(series.bars.map(\.date) == ["2025-10-14", "2025-12-30", "2025-12-31", "2026-10-09", "2026-10-16"])
        #expect(series.bars.map(\.close) == [700.0, 600.0, 610.0, 640.0, 660.0])
        #expect(series.last?.date == "2026-10-16")
    }

    @Test("Change since the last close before a day: YTD and week")
    func changeSince() throws {
        let series = try series()
        let ytd = try #require(series.percentChange(sinceCloseBefore: "2026-01-01"))
        #expect(abs(ytd - 8.1967) < 0.001)
        let week = try #require(series.percentChange(sinceCloseBefore: "2026-10-12"))
        #expect(abs(week - 3.125) < 0.001)
        #expect(series.percentChange(sinceCloseBefore: "2025-01-01") == nil)
        let session = try #require(series.percentChange(sessionsBack: 1))
        #expect(abs(session - 3.125) < 0.001)
        #expect(series.percentChange(sessionsBack: 5) == nil)
    }

    @Test("52-week closing range ignores bars older than a year")
    func range52() throws {
        let series = try series()
        #expect(series.high52 == 660.0)
        #expect(series.low52 == 600.0)
    }

    @Test("Error envelope and empty bars yield nothing")
    func empty() throws {
        let error = #"{"chart":{"result":null,"error":{"code":"Not Found"}}}"#
        let noBars = #"{"chart":{"result":[{"meta":{"symbol":"X"},"timestamp":[],"indicators":{"quote":[{"close":[]}]}}]}}"#
        #expect(try YahooDailyBarsProvider.parse(Data(error.utf8)) == nil)
        #expect(try YahooDailyBarsProvider.parse(Data(noBars.utf8)) == nil)
    }
}
