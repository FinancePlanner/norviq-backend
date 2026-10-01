import Foundation
@testable import StockPlanBackend
import Testing

@Suite("PilotBookBuilder")
struct PilotBookBuilderTests {
    // 2026-10-01T00:00:00Z
    private let asOf = Date(timeIntervalSince1970: 1_790_812_800)

    private func trade(_ symbol: String, _ side: PilotTradeSide, _ min: Double?, _ max: Double?, date: String = "2026-06-01", instrument: PilotInstrumentKind = .stock) -> PilotBookEntry {
        PilotBookEntry(symbol: symbol, side: side, instrument: instrument, transactionDate: date, amountMin: min, amountMax: max, marketValue: nil, period: nil)
    }

    @Test("bracket midpoint; 'Over $X' counts as X")
    func estimatedValue() {
        #expect(PilotBookBuilder.estimatedValue(min: 1001, max: 15000) == 8000.5)
        #expect(PilotBookBuilder.estimatedValue(min: 5_000_000, max: nil) == 5_000_000)
        #expect(PilotBookBuilder.estimatedValue(min: nil, max: 1000) == 1000)
        #expect(PilotBookBuilder.estimatedValue(min: nil, max: nil) == nil)
    }

    @Test("buys accumulate into normalized weights")
    func buysAccumulate() {
        let book = PilotBookBuilder.politicianBook([
            trade("AAPL", .buy, 15000, 15000),
            trade("MSFT", .buy, 5000, 5000),
        ], asOf: asOf)
        #expect(book.weights == ["AAPL": 0.75, "MSFT": 0.25])
    }

    @Test("partial sale subtracts midpoint; full sale zeroes")
    func sales() {
        let book = PilotBookBuilder.politicianBook([
            trade("AAPL", .buy, 20000, 20000, date: "2026-01-01"),
            trade("AAPL", .sell, 10000, 10000, date: "2026-02-01"),
            trade("MSFT", .buy, 10000, 10000, date: "2026-01-01"),
            trade("NVDA", .buy, 10000, 10000, date: "2026-01-01"),
            trade("NVDA", .sellFull, 1001, 15000, date: "2026-03-01"),
        ], asOf: asOf)
        #expect(book.weights == ["AAPL": 0.5, "MSFT": 0.5])
    }

    @Test("a sale of a position never seen is ignored")
    func sellOfUnseenPositionIgnored() {
        let book = PilotBookBuilder.politicianBook([
            trade("TSLA", .sell, 50000, 100_000),
            trade("AAPL", .buy, 1000, 1000),
        ], asOf: asOf)
        #expect(book.weights == ["AAPL": 1.0])
    }

    @Test("calls map to the underlying; puts are skipped and counted")
    func options() {
        let book = PilotBookBuilder.politicianBook([
            trade("NVDA", .buy, 1000, 1000, instrument: .call),
            trade("AAPL", .buy, 1000, 1000),
            trade("SPY", .buy, 50000, 50000, instrument: .put),
        ], asOf: asOf)
        #expect(book.weights == ["NVDA": 0.5, "AAPL": 0.5])
        #expect(book.skippedPuts == 1)
    }

    @Test("trades older than the lookback are ignored; order is by transaction date")
    func lookback() {
        let book = PilotBookBuilder.politicianBook([
            trade("AAPL", .sellFull, 1, 1, date: "2026-05-01"),
            trade("AAPL", .buy, 10000, 10000, date: "2026-04-01"),
            trade("KO", .buy, 10000, 10000, date: "2024-01-01"),
            trade("MSFT", .buy, 10000, 10000, date: "2026-04-01"),
        ], asOf: asOf)
        #expect(book.weights == ["MSFT": 1.0])
    }

    @Test("fund book uses the latest period's market values")
    func fundBook() {
        func hold(_ s: String, _ v: Double, _ p: String) -> PilotBookEntry {
            PilotBookEntry(symbol: s, side: .hold, instrument: .stock, transactionDate: nil, amountMin: nil, amountMax: nil, marketValue: v, period: p)
        }
        let book = PilotBookBuilder.fundBook([
            hold("AAPL", 300, "2026Q2"), hold("KO", 100, "2026Q2"), hold("OXY", 999, "2026Q1"),
        ])
        #expect(book.weights == ["AAPL": 0.75, "KO": 0.25])
    }

    @Test("empty input gives an empty book")
    func empty() {
        #expect(PilotBookBuilder.politicianBook([], asOf: asOf) == PilotBook(weights: [:], skippedPuts: 0))
        #expect(PilotBookBuilder.fundBook([]) == PilotBook(weights: [:], skippedPuts: 0))
    }
}
