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
}
