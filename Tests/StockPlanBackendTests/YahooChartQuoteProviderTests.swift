import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Yahoo chart quote provider")
struct YahooChartQuoteProviderTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    @Test("Reads price, previous close and market time from meta")
    func parsesMeta() throws {
        let json = """
        {"chart":{"result":[{"meta":{"symbol":"^GDAXI","currency":"EUR","regularMarketPrice":24806.97,\
        "chartPreviousClose":25104.36,"regularMarketTime":1791475200}}],"error":null}}
        """
        let quote = try #require(try YahooChartQuoteProvider.parse(data(json)))
        #expect(quote.symbol == "^GDAXI")
        #expect(quote.price == 24806.97)
        #expect(quote.previousClose == 25104.36)
        #expect(quote.marketTime == Date(timeIntervalSince1970: 1_791_475_200))
        #expect(abs(quote.changePercent - -1.1846) < 0.001)
    }

    @Test("Unknown symbol: Yahoo's error envelope yields no quote")
    func errorEnvelope() throws {
        let json = """
        {"chart":{"result":null,"error":{"code":"Not Found","description":"No data found, symbol may be delisted"}}}
        """
        #expect(try YahooChartQuoteProvider.parse(data(json)) == nil)
    }

    @Test("Missing or zero previous close, or missing price, yields no quote (never NaN or infinity)")
    func incompleteMeta() throws {
        let noPrevious = #"{"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":10,"regularMarketTime":1}}]}}"#
        let zeroPrevious = #"{"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":10,"chartPreviousClose":0,"regularMarketTime":1}}]}}"#
        let nullPrice = #"{"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":null,"chartPreviousClose":9,"regularMarketTime":1}}]}}"#
        #expect(try YahooChartQuoteProvider.parse(data(noPrevious)) == nil)
        #expect(try YahooChartQuoteProvider.parse(data(zeroPrevious)) == nil)
        #expect(try YahooChartQuoteProvider.parse(data(nullPrice)) == nil)
    }

    @Test("A non-JSON body (rate-limit HTML page) throws")
    func htmlThrows() {
        #expect(throws: (any Error).self) {
            try YahooChartQuoteProvider.parse(data("<html>Too Many Requests</html>"))
        }
    }

    @Test("Quotes older than 18 hours are stale")
    func freshness() {
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let fresh = IndexQuote(symbol: "A", price: 1, previousClose: 1, marketTime: now.addingTimeInterval(-17 * 3600))
        let stale = IndexQuote(symbol: "A", price: 1, previousClose: 1, marketTime: now.addingTimeInterval(-19 * 3600))
        #expect(YahooChartQuoteProvider.isFresh(fresh, now: now))
        #expect(!YahooChartQuoteProvider.isFresh(stale, now: now))
    }
}
