import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Daily board post")
struct DailyBoardPostTests {
    private var lisbon: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketBriefSchedule.timeZone
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        lisbon.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("The due date is the latest weekday whose evening window has opened")
    func schedule() {
        // Wednesday 14 Oct 2026, 22:30 Lisbon.
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 14, 22, 30)) == "2026-10-14")
        // Same morning still belongs to Tuesday.
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 14, 10, 0)) == "2026-10-13")
        // Monday morning is Friday.
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 12, 9, 0)) == "2026-10-09")
        // Saturday is Friday.
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 17, 11, 0)) == "2026-10-16")
    }

    @Test("A same-day stock move wins, a stale one does not, and yesterday's topic is skipped")
    func picker() {
        let stock = DailyBoardFacts.StockQuote(symbol: "NVDA", price: 131.2, changePercent: 4.2, onTradingDate: true)
        let quiet = DailyBoardFacts.StockQuote(symbol: "AAPL", price: 220, changePercent: 0.2, onTradingDate: true)
        let stale = DailyBoardFacts.StockQuote(symbol: "NVDA", price: 131.2, changePercent: 4.2, onTradingDate: false)
        let index = DailyBoardFacts.IndexMove(symbol: "^GSPC", name: "S&P 500", price: 5800, changePercent: 1.1)
        let fund = DailyBoardFacts.FundQuote(symbol: "SPY", price: 580, changePercent: 0.9, onTradingDate: true)
        let headline = DailyBoardFacts.Headline(title: "Chips rally", url: "https://example.com/chips", tickers: ["NVDA"])

        let hot = DailyBoardFacts.signals(stocks: [stock], indexes: [index], funds: [:], headlines: [headline])
        #expect(DailyBoardFacts.choose(hot, yesterday: nil)?.topic == .stock)
        #expect(DailyBoardFacts.choose(hot, yesterday: .stock)?.topic == .index)

        let withFund = DailyBoardFacts.signals(stocks: [], indexes: [index], funds: ["SPY": fund], headlines: [])
        let chosen = DailyBoardFacts.choose(withFund, yesterday: nil)
        #expect(chosen?.symbol == "SPY")
        #expect(chosen?.changePercent == 0.9)
        #expect(chosen?.name.contains("S&P 500") == true)

        let noFund = DailyBoardFacts.signals(
            stocks: [],
            indexes: [index],
            funds: ["SPY": DailyBoardFacts.FundQuote(symbol: "SPY", price: 580, changePercent: 0.9, onTradingDate: false)],
            headlines: []
        )
        #expect(DailyBoardFacts.choose(noFund, yesterday: nil)?.symbol == "^GSPC")

        let staleStock = DailyBoardFacts.signals(stocks: [stale, quiet], indexes: [index], funds: [:], headlines: [])
        #expect(DailyBoardFacts.choose(staleStock, yesterday: nil)?.topic == .index)

        let newsOnly = DailyBoardFacts.signals(stocks: [], indexes: [], funds: [:], headlines: [headline])
        #expect(DailyBoardFacts.choose(newsOnly, yesterday: nil)?.topic == .news)
        #expect(DailyBoardFacts.choose(DailyBoardSignals(), yesterday: nil) == nil)
    }

    @Test("Tickers are counted from the headlines and index symbols are left out")
    func tickers() {
        let headlines = [
            DailyBoardFacts.Headline(title: "NVDA rises", url: nil, tickers: ["NVDA", "^GSPC"]),
            DailyBoardFacts.Headline(title: "NVDA again", url: nil, tickers: ["NVDA", "AAPL"]),
            DailyBoardFacts.Headline(title: "Oil", url: nil, tickers: ["BZ=F"]),
        ]
        #expect(DailyBoardFacts.rankedTickers(headlines) == ["NVDA", "AAPL"])
    }

    @Test("A draft that invents a percent is rejected, and the disclosure is appended")
    func validator() {
        let grounded = [131.2, 4.2]
        let ok = DailyBoardValidator.accept(title: "NVDA rose 4.2%", body: "NVDA closed at 131.2, up 4.2%.", grounded: grounded)
        #expect(ok?.title == "NVDA rose 4.2%")
        #expect(ok?.body.contains("Not financial advice.") == true)
        #expect(DailyBoardValidator.accept(title: "NVDA rose 9.9%", body: "NVDA closed at 131.2.", grounded: grounded) == nil)
        #expect(DailyBoardValidator.accept(title: "Hi", body: "No numbers here.", grounded: []) == nil)
    }
}
