import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Technical signals")
struct TechnicalSignalsTests {
    // MARK: - Fixtures

    /// Builds daily candles from closes, one calendar day apart, ascending.
    /// `open`/`high`/`low` mirror the close so 52-week range assertions are
    /// driven purely by the close series.
    private func candles(_ closes: [Double]) -> [PriceBarResponse] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let start = DateComponents(calendar: calendar, year: 2024, month: 1, day: 1).date!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        return closes.enumerated().map { index, close in
            let date = calendar.date(byAdding: .day, value: index, to: start)!
            return PriceBarResponse(
                date: formatter.string(from: date),
                open: close,
                high: close,
                low: close,
                close: close,
                volume: 1000
            )
        }
    }

    /// 200 sessions falling from 300 to 101, then 60 sessions rising in steps of
    /// 4. The 50/200 pair crosses upward at index 244.
    private var decliningThenRising: [Double] {
        let declining: [Double] = (0 ..< 200).map { index in 300.0 - Double(index) }
        let rising: [Double] = (1 ... 60).map { step in 100.0 + 4.0 * Double(step) }
        return declining + rising
    }

    /// Mirror image of `decliningThenRising`: the 50/200 pair crosses downward
    /// at index 244.
    private var risingThenDeclining: [Double] {
        let rising: [Double] = (0 ..< 200).map { index in 100.0 + Double(index) }
        let declining: [Double] = (1 ... 60).map { step in 300.0 - 4.0 * Double(step) }
        return rising + declining
    }

    /// StockCharts' published RSI worked example. The first Wilder value after
    /// 14 changes is 70.53.
    private let wilderTextbookCloses: [Double] = [
        44.3389, 44.0902, 44.1497, 43.6124, 44.3278, 44.8264, 45.0955, 45.4245,
        45.8433, 46.0826, 45.8931, 46.0328, 45.6140, 46.2820, 46.2820,
    ]

    /// The same example continued, so the smoothing recursion is exercised
    /// rather than only its seed.
    private var wilderTextbookClosesExtended: [Double] {
        wilderTextbookCloses + [
            46.0000, 46.0300, 46.4100, 46.2200, 45.6400, 46.2100, 46.2500, 45.7100,
            46.4500, 45.7800, 45.3500, 44.0300, 44.1800, 44.2200, 44.5700, 43.4200,
            42.6600, 43.1300,
        ]
    }

    /// 1%-a-session compounding advance, then a 1%-a-session retreat.
    private var compoundingAdvance: [Double] {
        (0 ..< 60).map { 100.0 * pow(1.01, Double($0)) }
    }

    private var compoundingRetreat: [Double] {
        let peak = compoundingAdvance[59]
        return (0 ..< 40).map { peak * pow(0.99, Double($0 + 1)) }
    }

    // MARK: - Moving averages and trend

    @Test("SMA 50 and 200 average the trailing closes")
    func movingAveragesAverageTrailingCloses() throws {
        let closes = (1 ... 300).map(Double.init)
        let signals = try #require(TechnicalSignals.compute(symbol: "aapl", bars: candles(closes)))

        #expect(signals.symbol == "AAPL")
        #expect(signals.close == 300)
        #expect(signals.asOf == "2024-10-26")
        #expect(signals.sma50 == 275.5)
        #expect(signals.sma200 == 200.5)
        #expect(signals.trend == .aboveBoth)
        #expect(signals.cross == TechnicalCross.none)
    }

    @Test("A close under both averages reads as belowBoth")
    func closeUnderBothAveragesReadsBelowBoth() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "MSFT", bars: candles(Array(risingThenDeclining[0 ..< 250])))
        )
        #expect(signals.trend == .belowBoth)
    }

    @Test("A close between the two averages reads as mixed")
    func closeBetweenAveragesReadsMixed() throws {
        // Rising ramp: the 50 sits above the 200, so a close placed between them
        // is above one and below the other.
        var closes = (1 ... 300).map(Double.init)
        closes[299] = 250.0 // between sma200 (~200) and sma50 (~275)
        let signals = try #require(TechnicalSignals.compute(symbol: "MSFT", bars: candles(closes)))

        let sma50 = try #require(signals.sma50)
        let sma200 = try #require(signals.sma200)
        #expect(signals.close < sma50)
        #expect(signals.close > sma200)
        #expect(signals.trend == .mixed)
    }

    // MARK: - Crosses

    @Test("A 50/200 upward flip inside the last 10 sessions is a golden cross")
    func goldenCrossInsideTheWindow() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles(Array(decliningThenRising[0 ..< 250])))
        )

        #expect(signals.sma50 == 202.0)
        #expect(signals.sma200 == 182.125)
        #expect(signals.cross == .goldenCross)
    }

    @Test("A 50/200 downward flip inside the last 10 sessions is a death cross")
    func deathCrossInsideTheWindow() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles(Array(risingThenDeclining[0 ..< 250])))
        )
        #expect(signals.cross == .deathCross)
    }

    @Test("A flip older than 10 sessions is not reported as a cross")
    func crossOlderThanTheWindowIsNone() throws {
        // Same series, 10 more sessions: the flip at index 244 is now 15 back.
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles(decliningThenRising))
        )
        #expect(signals.cross == TechnicalCross.none)
    }

    // MARK: - RSI

    @Test("RSI 14 matches Wilder's worked example seed (70.53)")
    func rsiMatchesWilderSeed() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles(wilderTextbookCloses))
        )
        let rsi = try #require(signals.rsi14)
        #expect(abs(rsi - 70.5328) < 0.0005)
    }

    @Test("RSI 14 keeps smoothing past the seed window")
    func rsiKeepsSmoothingPastTheSeed() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles(wilderTextbookClosesExtended))
        )
        let rsi = try #require(signals.rsi14)
        #expect(abs(rsi - 37.7877) < 0.0005)
    }

    @Test("An unbroken advance pins RSI 14 at 100")
    func rsiIsHundredWithoutLosses() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles((1 ... 20).map(Double.init)))
        )
        #expect(signals.rsi14 == 100)
    }

    // MARK: - MACD

    @Test("MACD reports the 12/26 line, its 9-period signal, and their difference")
    func macdReportsLineSignalAndHistogram() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles(compoundingAdvance))
        )
        let macd = try #require(signals.macd)

        #expect(abs(macd.line - 10.561288) < 0.0005)
        #expect(abs(macd.signal - 10.179556) < 0.0005)
        #expect(abs(macd.histogram - (macd.line - macd.signal)) < 1e-9)
        #expect(macd.sign == .positive)
    }

    @Test("The MACD sign flips negative once the advance reverses")
    func macdSignFlipsOnReversal() throws {
        let reversed = compoundingAdvance + Array(compoundingRetreat[0 ..< 20])
        let signals = try #require(TechnicalSignals.compute(symbol: "AAPL", bars: candles(reversed)))
        let macd = try #require(signals.macd)

        #expect(macd.histogram < 0)
        #expect(macd.sign == .negative)
    }

    // MARK: - 52-week range

    @Test("A close at the 52-week high puts the position at 100")
    func positionIsHundredAtTheHigh() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles((1 ... 300).map(Double.init)))
        )

        #expect(signals.fiftyTwoWeek.high == 300)
        #expect(signals.fiftyTwoWeek.low == 49) // 252-session window, not all 300
        #expect(signals.fiftyTwoWeek.positionPct == 100)
    }

    @Test("A close at the 52-week low puts the position at 0")
    func positionIsZeroAtTheLow() throws {
        let closes = (1 ... 300).map(Double.init).reversed()
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles(Array(closes)))
        )

        #expect(signals.fiftyTwoWeek.low == 1)
        #expect(signals.fiftyTwoWeek.high == 252)
        #expect(signals.fiftyTwoWeek.positionPct == 0)
    }

    @Test("A close halfway up the 52-week range puts the position at 50")
    func positionIsFiftyMidRange() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles([10, 30, 20]))
        )
        #expect(signals.fiftyTwoWeek.positionPct == 50)
    }

    // MARK: - Thin data

    @Test("Averages, RSI, and MACD are nil until enough sessions exist")
    func thinSeriesYieldsNils() throws {
        let signals = try #require(
            TechnicalSignals.compute(symbol: "AAPL", bars: candles((1 ... 30).map(Double.init)))
        )

        #expect(signals.sma50 == nil)
        #expect(signals.sma200 == nil)
        #expect(signals.macd == nil) // needs 26 + 9 - 1 sessions
        #expect(signals.rsi14 != nil) // needs only 15
        #expect(signals.trend == .mixed)
        #expect(signals.cross == TechnicalCross.none)
    }

    @Test("A single session still reports a close and an as-of date")
    func singleSessionReportsCloseOnly() throws {
        let signals = try #require(TechnicalSignals.compute(symbol: "AAPL", bars: candles([42])))

        #expect(signals.close == 42)
        #expect(signals.asOf == "2024-01-01")
        #expect(signals.rsi14 == nil)
        #expect(signals.macd == nil)
        #expect(signals.fiftyTwoWeek.high == 42)
        #expect(signals.fiftyTwoWeek.low == 42)
    }

    @Test("No candles means no signals at all")
    func emptySeriesYieldsNothing() {
        #expect(TechnicalSignals.compute(symbol: "AAPL", bars: []) == nil)
    }

    // MARK: - Window and ordering

    @Test("Only the last 300 sessions feed the calculation")
    func olderSessionsOutsideTheWindowAreIgnored() throws {
        let recent = (1 ... 300).map(Double.init)
        let withPrehistory = (0 ..< 100).map { _ in 5000.0 } + recent

        let capped = try #require(TechnicalSignals.compute(symbol: "AAPL", bars: candles(recent)))
        let full = try #require(TechnicalSignals.compute(symbol: "AAPL", bars: candles(withPrehistory)))

        #expect(full.sma50 == capped.sma50)
        #expect(full.sma200 == capped.sma200)
        #expect(full.rsi14 == capped.rsi14)
        #expect(full.fiftyTwoWeek == capped.fiftyTwoWeek)
    }

    // MARK: - Configuration

    @Test("The upstream history window starts 600 calendar days back, in UTC")
    func historyStartIsSixHundredDaysBack() {
        let now = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01T00:00:00Z

        #expect(TechnicalSignalsConfig.historyStart(relativeTo: now) == "2023-05-12")
        #expect(TechnicalSignalsConfig.redisKey("AAPL") == "market:technicals:AAPL")
    }

    @Test("Candles arriving newest-first are still read chronologically")
    func unsortedCandlesAreOrderedBeforeComputing() throws {
        let closes = (1 ... 300).map(Double.init)
        let descending = Array(candles(closes).reversed())
        let signals = try #require(TechnicalSignals.compute(symbol: "AAPL", bars: descending))

        #expect(signals.close == 300)
        #expect(signals.sma50 == 275.5)
        #expect(signals.asOf == "2024-10-26")
    }
}
