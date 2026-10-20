import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

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

    // MARK: - When

    @Test("Weekdays fall due at 22:30 Lisbon, weekends at 10:00, and only the latest day is due")
    func schedule() {
        // Wednesday 14 Oct 2026.
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 14, 22, 30)) == "2026-10-14")
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 14, 10, 0)) == "2026-10-13")
        // Saturday 17 Oct: before 10:00 it is still Friday.
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 17, 9, 59)) == "2026-10-16")
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 17, 10, 0)) == "2026-10-17")
        // Sunday 10:00 is Sunday; a Saturday missed until then is not written late.
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 18, 10, 0)) == "2026-10-18")
        // Monday morning is Sunday.
        #expect(DailyBoardSchedule.latestDueDate(now: date(2026, 10, 19, 9, 0)) == "2026-10-18")
    }

    @Test("Each weekday has its slot, and every slot falls back to ETF then macro")
    func rotation() {
        #expect(DailyBoardRotation.topics(for: "2026-10-19") == [.mag7, .etf, .macro])
        #expect(DailyBoardRotation.topics(for: "2026-10-20") == [.stock, .etf, .macro])
        #expect(DailyBoardRotation.topics(for: "2026-10-21") == [.macro, .etf])
        #expect(DailyBoardRotation.topics(for: "2026-10-22") == [.etf, .macro])
        #expect(DailyBoardRotation.topics(for: "2026-10-23") == [.stock, .etf, .macro])
        #expect(DailyBoardRotation.topics(for: "2026-10-24") == [.weekRecap, .etf, .macro])
        #expect(DailyBoardRotation.topics(for: "2026-10-25") == [.weekAhead, .etf, .macro])
        #expect(DailyBoardRotation.topics(for: "not a day").isEmpty)
    }

    // MARK: - Picks

    @Test("Hot stock: the biggest same-day move of at least 1%, Mag 7 excluded, with its headline")
    func hotStock() {
        let day = "2026-10-20"
        let amd = DailyBoardFacts.StockQuote(symbol: "AMD", price: 151.2, changePercent: -6.4, sessionDate: day)
        let nvda = DailyBoardFacts.StockQuote(symbol: "NVDA", price: 131.2, changePercent: 9.1, sessionDate: day)
        let quiet = DailyBoardFacts.StockQuote(symbol: "KO", price: 70, changePercent: 0.4, sessionDate: day)
        let stale = DailyBoardFacts.StockQuote(symbol: "INTC", price: 30, changePercent: 12, sessionDate: "2026-10-19")
        let headline = DailyBoardFacts.Headline(title: "AMD slides 6.4% on guidance", url: nil, tickers: ["AMD"])

        let pick = DailyBoardFacts.hotStock([amd, nvda, quiet, stale], headlines: [headline], day: day)
        #expect(pick?.0.symbol == "AMD")
        #expect(pick?.1?.title == "AMD slides 6.4% on guidance")
        #expect(DailyBoardFacts.hotStock([nvda, quiet, stale], headlines: [], day: day) == nil)
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

    private func entry(_ day: String, _ topic: DailyBoardTopic, _ tags: String...) -> DailyBoardHistory.Entry {
        DailyBoardHistory.Entry(day: day, topic: topic, tags: [topic.rawValue] + tags + ["ai"])
    }

    private func snapshot(_ symbol: String, fiveDay: Double) -> DailyBoardBuilders.StockSnapshot {
        DailyBoardBuilders.StockSnapshot(
            symbol: symbol, price: 100, changePercent: 1, sessionDate: "2026-10-19",
            metrics: ["5DayPriceReturnDaily": fiveDay]
        )
    }

    @Test("Mag 7: the biggest five-day move not covered in the last three Mag 7 posts")
    func mag7Pick() {
        let snapshots = [snapshot("NVDA", fiveDay: -8), snapshot("AAPL", fiveDay: 3), snapshot("TSLA", fiveDay: 6)]
        #expect(DailyBoardBuilders.pickMag7(snapshots, history: DailyBoardHistory())?.symbol == "NVDA")
        let history = DailyBoardHistory(entries: [
            entry("2026-10-12", .mag7, "nvda"),
            entry("2026-10-05", .mag7, "msft"),
            entry("2026-09-28", .mag7, "googl"),
            entry("2026-09-21", .mag7, "tsla"),
        ])
        #expect(DailyBoardBuilders.pickMag7(snapshots, history: history)?.symbol == "TSLA")
        // All recent: still a pick rather than nothing.
        let all = DailyBoardHistory(entries: [entry("2026-10-12", .mag7, "nvda"), entry("2026-10-05", .mag7, "aapl"), entry("2026-09-28", .mag7, "tsla")])
        #expect(DailyBoardBuilders.pickMag7(snapshots, history: all)?.symbol == "NVDA")
    }

    @Test("ETF: never-covered funds first in catalog order, then the one covered longest ago")
    func etfOrder() {
        let first = DailyBoardBuilders.etfOrder(history: DailyBoardHistory()).map(\.symbol)
        #expect(first == DailyBoardCatalog.funds.map(\.symbol))
        let history = DailyBoardHistory(entries: DailyBoardCatalog.funds.enumerated().map { index, fund in
            entry(DailyBoardDays.adding(-7 * index, to: "2026-10-15")!, .etf, DailyBoardHistory.tag(fund.symbol))
        })
        #expect(DailyBoardBuilders.etfOrder(history: history).first?.symbol == DailyBoardCatalog.funds.last?.symbol)
    }

    @Test("Macro: inflation in the week of a release, otherwise the angle used least recently")
    func macroAngle() {
        // US CPI on Wed 2026-10-14: that Wednesday is a release week.
        #expect(DailyBoardBuilders.macroAngle(day: "2026-10-14", history: DailyBoardHistory()) == "inflation")
        let covered = DailyBoardHistory(entries: [entry("2026-10-14", .macro, "inflation")])
        #expect(DailyBoardBuilders.macroAngle(day: "2026-10-14", history: covered) != "inflation")
        // 2026-10-21: nothing released in the 7 days before.
        #expect(DailyBoardBuilders.macroAngle(day: "2026-10-21", history: DailyBoardHistory()) == "rates")
        let rotated = DailyBoardHistory(entries: [
            entry("2026-10-14", .macro, "rates"),
            entry("2026-10-07", .macro, "us_vs_ea"),
            entry("2026-09-30", .macro, "core_gap"),
        ])
        #expect(DailyBoardBuilders.macroAngle(day: "2026-10-21", history: rotated) == "core_gap")
    }

    // MARK: - Facts

    @Test("A stock's facts come out rounded, and every figure is grounded with both signs")
    func stockFacts() throws {
        var snapshot = snapshot("NVDA", fiveDay: -8.04)
        snapshot.price = 131.237
        snapshot.changePercent = -4.26
        snapshot.metrics.merge([
            "yearToDatePriceReturnDaily": 61.4, "52WeekHigh": 152.89, "52WeekLow": 86.62,
            "marketCapitalization": 3_212_345, "peTTM": 51.27,
        ]) { $1 }
        let candidate = try #require(DailyBoardBuilders.stock(snapshot, topic: .mag7))
        let values = Dictionary(uniqueKeysWithValues: candidate.facts.map { ($0.label, $0.value) })
        #expect(values["Close"] == "131.24 USD")
        #expect(values["Change on the session"] == "-4.3%")
        #expect(values["Change this year"] == "+61.4%")
        #expect(values["Market cap"] == "$3.21 trillion")
        #expect(values["Price to trailing earnings (P/E)"] == "51.3x")
        #expect(values["Distance from the 52-week high"] == "-14.2%")
        #expect(values["Session"] == "Monday 2026-10-19")
        for number in [131.24, -4.3, 4.3, 61.4, 3.21, 51.3, 14.2, 152.89] {
            #expect(candidate.grounded.contains(number), "\(number) not grounded")
        }
        #expect(candidate.tags == ["mag7", "nvda", "ai"])

        let bare = DailyBoardBuilders.StockSnapshot(symbol: "X", price: 10, changePercent: 1, sessionDate: "2026-10-19")
        #expect(DailyBoardBuilders.stock(bare, topic: .stock) == nil)
    }

    @Test("ETF facts come from the daily bars and the catalog's fee")
    func etfFacts() throws {
        let bars = [
            DailyBar(date: "2025-10-10", close: 500), DailyBar(date: "2025-12-31", close: 550),
            DailyBar(date: "2026-10-09", close: 590), DailyBar(date: "2026-10-12", close: 591),
            DailyBar(date: "2026-10-13", close: 592),
            DailyBar(date: "2026-10-14", close: 594), DailyBar(date: "2026-10-15", close: 596),
            DailyBar(date: "2026-10-16", close: 600),
        ]
        let fund = try #require(DailyBoardCatalog.funds.first { $0.symbol == "SPY" })
        let candidate = try #require(DailyBoardBuilders.etf(fund, series: DailyBarSeries(symbol: "SPY", currency: "USD", bars: bars)))
        let values = Dictionary(uniqueKeysWithValues: candidate.facts.map { ($0.label, $0.value) })
        #expect(values["Total expense ratio per year"] == "0.0945%")
        #expect(values["Close"] == "600.00 USD")
        #expect(values["Change this year"] == "+9.1%")
        #expect(values["Change over 1 year"] == "+20.0%")
        #expect(values["Change over 5 sessions"] == "+1.7%")
        #expect(candidate.grounded.contains(0.0945))
        #expect(candidate.tags == ["etf", "spy", "ai"])
    }

    private var macroInputs: DailyBoardBuilders.MacroInputs {
        DailyBoardBuilders.MacroInputs(
            usCPI: .init(period: "2026-09-01", value: 2.94, prior: 2.71),
            usCore: .init(period: "2026-09-01", value: 3.12, prior: 3.08),
            eaCPI: .init(period: "2026-09-01", value: 2.2, prior: 2.1),
            eaCore: .init(period: "2026-09-01", value: 2.4, prior: 2.3),
            fedRate: .init(period: "2026-10-01", value: 4.25),
            ecbRate: .init(period: "2026-10-01", value: 2.15),
            nextFOMC: "Wednesday 2026-10-28",
            nextECB: "Thursday 2026-10-29"
        )
    }

    @Test("Macro angles: each builds its own computed figures, and missing data means no post")
    func macroFacts() throws {
        let rates = try #require(DailyBoardBuilders.macro(angle: "rates", macroInputs))
        let values = Dictionary(uniqueKeysWithValues: rates.facts.map { ($0.label, $0.value) })
        #expect(values["Fed rate minus ECB rate"] == "+2.10 percentage points")
        #expect(values["US real policy rate (Fed rate minus CPI inflation)"] == "+1.31 percentage points")
        #expect(values["US CPI inflation (September 2026)"] == "2.94%")
        #expect(rates.tags == ["macro", "rates", "ai"])

        let inflation = try #require(DailyBoardBuilders.macro(angle: "inflation", macroInputs))
        #expect(inflation.grounded.contains(0.23))
        #expect(DailyBoardBuilders.macro(angle: "core_gap", macroInputs) != nil)
        #expect(DailyBoardBuilders.macro(angle: "us_vs_ea", macroInputs) != nil)

        var empty = DailyBoardBuilders.MacroInputs()
        empty.usCPI = macroInputs.usCPI
        #expect(DailyBoardBuilders.macro(angle: "rates", empty) == nil)
        #expect(DailyBoardBuilders.macro(angle: "us_vs_ea", empty) == nil)
    }

    @Test("Week recap measures from the last close before Monday")
    func weekRecap() throws {
        func series(_ symbol: String, _ before: Double, _ friday: Double) -> DailyBarSeries {
            DailyBarSeries(symbol: symbol, bars: [
                DailyBar(date: "2026-10-09", close: before), DailyBar(date: "2026-10-16", close: friday),
            ])
        }
        let indexes = [("S&P 500", series("^GSPC", 6000, 6120)), ("DAX", series("^GDAXI", 24000, 23760)), ("Nikkei 225", series("^N225", 40000, 40400))]
        let mag7 = [series("NVDA", 100, 108), series("AAPL", 200, 196)]
        let candidate = try #require(DailyBoardBuilders.weekRecap(day: "2026-10-17", indexes: indexes, mag7: mag7))
        let values = Dictionary(uniqueKeysWithValues: candidate.facts.map { ($0.label, $0.value) })
        #expect(values["S&P 500, change on the week"] == "+2.0%")
        #expect(values["DAX, change on the week"] == "-1.0%")
        #expect(values["Best Mag 7 stock of the week, NVDA"] == "+8.0%")
        #expect(values["Worst Mag 7 stock of the week, AAPL"] == "-2.0%")
        #expect(DailyBoardBuilders.weekRecap(day: "2026-10-17", indexes: Array(indexes.prefix(2)), mag7: mag7) == nil)
    }

    @Test("Week ahead lists the next seven days' central banks, prints and watched earnings")
    func weekAhead() throws {
        let events = WorldMacroCalendar.events(from: "2026-10-26", through: "2026-11-01")
        #expect(events.map(\.name).contains("ECB rate decision"))
        #expect(events.map(\.name).contains("Bank of Japan rate decision"))
        #expect(events.map(\.name).contains("Fed rate decision (FOMC)"))
        let earnings = [
            DailyBoardBuilders.Earnings(symbol: "MSFT", date: "2026-10-28", hour: "amc", epsEstimate: 3.67, revenueEstimate: 75_300_000_000),
            DailyBoardBuilders.Earnings(symbol: "TINY", date: "2026-10-28", epsEstimate: 0.1),
        ]
        let candidate = try #require(DailyBoardBuilders.weekAhead(day: "2026-10-25", events: events, earnings: earnings, macro: macroInputs))
        let values = Dictionary(uniqueKeysWithValues: candidate.facts.map { ($0.label, $0.value) })
        #expect(values["MSFT earnings"] == "Wednesday 2026-10-28 after the close")
        #expect(values["MSFT consensus revenue estimate, billions"] == "75.3")
        #expect(values["TINY earnings"] == nil)
        #expect(values["Thursday 2026-10-29"] == "ECB rate decision")
    }

    @Test("Calendars return dates in a window and nothing past the end of a table")
    func calendars() throws {
        #expect(WorldMacroCalendar.events(from: "2026-11-04", through: "2026-11-04").map(\.name) == ["Euro-area inflation flash (HICP)"])
        #expect(WorldMacroCalendar.events(from: "2028-06-01", through: "2028-06-07").isEmpty)
        let print = try BLSCPIReleaseCalendar.nextPrint(after: #require(FOMCCalendar.dayFormatter.date(from: "2026-12-11")), lastOfficial: nil)
        #expect(print?.date == "2027-01-13")
        #expect(try FOMCCalendar.nextMeeting(after: #require(FOMCCalendar.dayFormatter.date(from: "2026-12-10")))?.startDate == "2027-01-26")
    }

    // MARK: - Validator

    private static let goodBody = """
    Nvidia closed at 131.24 USD on Monday, down 4.3% on the session and 8.0% over five days. \
    The drop takes it 14.2% below its 52-week high of 152.89 USD, though the stock is still up 61.4% this year.

    Even after the slide the market values the company at $3.21 trillion, and the stock trades at 51.3x \
    trailing earnings. That multiple prices in years of fast growth in data-centre sales, so a weak week \
    moves the valuation more than it would for a slower business with steadier margins.

    A five-day fall of this size has come before every recent earnings report, and it often reversed once \
    the numbers were out. It could also mark the start of a longer cooling in chip demand.

    Is 51.3x trailing earnings still a fair price for a company that is up 61.4% this year?
    """

    private static let grounded: [Double] = [131.24, -4.3, 4.3, -8.0, 8.0, -14.2, 14.2, 152.89, 61.4, 3.21, 51.3]

    @Test("A grounded explainer with figures and a closing question passes, with the disclosure appended")
    func validatorAccepts() throws {
        let accepted = try DailyBoardValidator.check(
            title: "Nvidia fell 4.3% to 131.24 USD", body: Self.goodBody, grounded: Self.grounded
        ).get()
        #expect(accepted.body.hasSuffix(DailyBoardValidator.disclosure))
        // A sell-off or a buyback is not advice.
        let words = Self.goodBody.replacingOccurrences(of: "Even after the slide", with: "Even after the sell-off and a buyback")
        #expect(DailyBoardValidator.accept(title: "Nvidia fell 4.3%", body: words, grounded: Self.grounded) != nil)
        // An em dash becomes a comma instead of a rejection.
        let dashed = Self.goodBody.replacingOccurrences(of: ", though", with: " \u{2014} though")
        let cleaned = try #require(DailyBoardValidator.accept(title: "Nvidia fell 4.3%", body: dashed, grounded: Self.grounded))
        #expect(!cleaned.body.contains("\u{2014}"))
    }

    @Test("Slop, advice, invented numbers, thin figures, no question and bad length are each rejected")
    func validatorRejects() {
        func reason(_ body: String, title: String = "Nvidia fell 4.3%") -> DailyBoardValidator.Rejection? {
            if case let .failure(reason) = DailyBoardValidator.check(title: title, body: body, grounded: Self.grounded) {
                return reason
            }
            return nil
        }
        let body = Self.goodBody
        #expect(reason(body.replacingOccurrences(of: "That multiple", with: "In today's landscape that multiple")) == .phrase("landscape"))
        #expect(reason(body.replacingOccurrences(of: "That multiple", with: "Investors should note that multiple")) == .advice("Investors should"))
        #expect(reason(body.replacingOccurrences(of: "Even after the slide", with: "Consider buying because")) == .advice("Consider buying"))
        #expect(reason(body.replacingOccurrences(of: "61.4% this year?", with: "72.5% this year?")) == .ungrounded)
        #expect(reason(body.replacingOccurrences(of: "this year?", with: "this year.")) == .noQuestion)
        #expect(reason(body.replacingOccurrences(of: "steadier margins.", with: "steadier margins!")) == .phrase("!"))
        #expect(reason("Too short. Is it?") == .length(words: 4))
        #expect(reason(body, title: "Nvidia fell 4.3%!") == .title)
        let noFigures = String(repeating: "The chip maker had a rough week and the mood turned. ", count: 9) + "\n\nIs the mood about to turn?"
        #expect(reason(noFigures) == .figures(0))
    }

    // MARK: - Retry

    private final class ScriptedWriter: DailyBoardWriting, @unchecked Sendable {
        var drafts: [(String, String)]
        var prompts: [String] = []

        init(_ drafts: [(String, String)]) {
            self.drafts = drafts
        }

        func draft(prompt: String, on _: Request) async throws -> (title: String, body: String) {
            prompts.append(prompt)
            return drafts.removeFirst()
        }
    }

    private var candidate: DailyBoardCandidate {
        DailyBoardCandidate(topic: .mag7, name: "NVDA", symbol: "NVDA", grounded: Self.grounded)
    }

    @Test("A rejected draft gets one more try with the reason; two rejections throw")
    func retry() async throws {
        let app = try await Application.make(.testing)
        do {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let bad = ("Nvidia fell 4.3%", Self.goodBody.replacingOccurrences(of: "That multiple", with: "Let's be clear: that multiple"))
            let good = ("Nvidia fell 4.3%", Self.goodBody)

            let recovers = ScriptedWriter([bad, good])
            let accepted = try await DailyBoardPublisher.write(candidate, day: "2026-10-19", writer: recovers, on: req)
            #expect(accepted.title == "Nvidia fell 4.3%")
            #expect(recovers.prompts.count == 2)
            #expect(recovers.prompts[1].contains("rejected because it used \"let's\""))

            let fails = ScriptedWriter([bad, bad])
            await #expect(throws: DailyBoardPostError.self) {
                try await DailyBoardPublisher.write(candidate, day: "2026-10-19", writer: fails, on: req)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
