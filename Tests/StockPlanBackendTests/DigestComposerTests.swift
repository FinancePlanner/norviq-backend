import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Digest schedule")
struct DigestScheduleTests {
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return try #require(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)))
    }

    private let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    @Test("Due on the chosen weekday once the local hour has passed")
    func dueAfterLocalHour() throws {
        // 2026-10-18 is a Sunday; Lisbon is UTC+1 (summer time), so 18:00 local = 17:00Z.
        let due = try DigestSchedule.duePeriod(now: utc(2026, 10, 18, 17, 5), timeZone: lisbon, weekday: 7, localHour: 18)
        #expect(due == .init(start: "2026-10-12", end: "2026-10-18"))
        #expect(try DigestSchedule.duePeriod(now: utc(2026, 10, 18, 16, 59), timeZone: lisbon, weekday: 7, localHour: 18) == nil)
    }

    @Test("Not due on other weekdays")
    func otherWeekday() throws {
        // Monday 2026-10-19, 18:30 Lisbon.
        #expect(try DigestSchedule.duePeriod(now: utc(2026, 10, 19, 17, 30), timeZone: lisbon, weekday: 7, localHour: 18) == nil)
    }

    @Test("Lisbon autumn DST Sunday: 18:00 local is 18:00Z")
    func lisbonAutumnDST() throws {
        // Clocks go back at 02:00 on Sunday 2026-10-25; from then on Lisbon is UTC+0.
        #expect(try DigestSchedule.duePeriod(now: utc(2026, 10, 25, 17, 59), timeZone: lisbon, weekday: 7, localHour: 18) == nil)
        let due = try DigestSchedule.duePeriod(now: utc(2026, 10, 25, 18, 0), timeZone: lisbon, weekday: 7, localHour: 18)
        #expect(due == .init(start: "2026-10-19", end: "2026-10-25"))
    }

    @Test("Lisbon spring DST Sunday: 18:00 local is 17:00Z")
    func lisbonSpringDST() throws {
        // Clocks go forward at 01:00Z on Sunday 2027-03-28; from then on Lisbon is UTC+1.
        #expect(try DigestSchedule.duePeriod(now: utc(2027, 3, 28, 16, 59), timeZone: lisbon, weekday: 7, localHour: 18) == nil)
        let due = try DigestSchedule.duePeriod(now: utc(2027, 3, 28, 17, 0), timeZone: lisbon, weekday: 7, localHour: 18)
        #expect(due == .init(start: "2027-03-22", end: "2027-03-28"))
    }

    @Test("New York DST end: 18:00 EST is 23:00Z")
    func newYorkDST() throws {
        // US clocks go back on Sunday 2026-11-01.
        #expect(try DigestSchedule.duePeriod(now: utc(2026, 11, 1, 22, 59), timeZone: newYork, weekday: 7, localHour: 18) == nil)
        #expect(try DigestSchedule.duePeriod(now: utc(2026, 11, 1, 23, 0), timeZone: newYork, weekday: 7, localHour: 18) != nil)
    }

    @Test("Stops being due six hours after the send time")
    func lateness() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        #expect(try DigestSchedule.duePeriod(now: utc(2026, 10, 18, 16, 0), timeZone: zone, weekday: 7, localHour: 10) != nil)
        #expect(try DigestSchedule.duePeriod(now: utc(2026, 10, 18, 16, 1), timeZone: zone, weekday: 7, localHour: 10) == nil)
    }

    @Test("Day shifting crosses month and year boundaries")
    func shift() {
        #expect(DigestSchedule.shift("2026-11-01", byDays: -10) == "2026-10-22")
        #expect(DigestSchedule.shift("2026-12-28", byDays: 7) == "2027-01-04")
    }
}

@Suite("Digest composer")
struct DigestComposerTests {
    private let period = DigestSchedule.Period(start: "2026-10-19", end: "2026-10-25")

    private var positions: [DigestPosition] {
        [
            DigestPosition(symbol: "AAPL", currency: "USD", shares: 10),
            DigestPosition(symbol: "MISSING", currency: "USD", shares: 1),
            DigestPosition(symbol: "NVDA", currency: "USD", shares: 5),
            DigestPosition(symbol: "SAP", currency: "EUR", shares: 2),
        ]
    }

    private var closes: [String: [DigestPriceBar]] {
        [
            // A bar inside the week must not be taken as the starting close.
            "AAPL": [.init(date: "2026-10-16", close: 100), .init(date: "2026-10-19", close: 105), .init(date: "2026-10-23", close: 110)],
            "NVDA": [.init(date: "2026-10-16", close: 200), .init(date: "2026-10-23", close: 260)],
            "SAP": [.init(date: "2026-10-16", close: 150), .init(date: "2026-10-23", close: 147)],
        ]
    }

    @Test("Week move per currency from closing prices, largest book first")
    func holdingsTotals() {
        let result = DigestFactsCollector.holdings(positions: positions, closes: closes, period: period)
        #expect(result.priced == 3)
        #expect(result.moves == [
            DigestCurrencyMove(currency: "USD", startValue: 2000, endValue: 2400, change: 400, changePercent: 20),
            DigestCurrencyMove(currency: "EUR", startValue: 300, endValue: 294, change: -6, changePercent: -2),
        ])
    }

    @Test("Movers ranked by absolute contribution")
    func movers() {
        let result = DigestFactsCollector.holdings(positions: positions, closes: closes, period: period)
        #expect(result.movers.map(\.symbol) == ["NVDA", "AAPL", "SAP"])
        #expect(result.movers.first?.contribution == 300)
        #expect(result.movers.first?.changePercent == 30)
    }

    @Test("A position without a close before the week is left out, not guessed")
    func noStartingClose() {
        let result = DigestFactsCollector.holdings(
            positions: [DigestPosition(symbol: "NEW", currency: "USD", shares: 1)],
            closes: ["NEW": [.init(date: "2026-10-20", close: 10), .init(date: "2026-10-23", close: 12)]],
            period: period
        )
        #expect(result.priced == 0)
        #expect(result.moves.isEmpty)
    }

    @Test("Headline names the lead mover when it carried the week")
    func headline() {
        let result = DigestFactsCollector.holdings(positions: positions, closes: closes, period: period)
        var payload = DigestPayload(periodStart: period.start, periodEnd: period.end)
        payload.holdings = result.moves
        payload.movers = result.movers
        #expect(DigestComposer.headline(payload) == "Your week: +$400.00 (+20.00%). NVDA did most of it.")
        #expect(DigestComposer.subject(payload) == "Your week: +$400.00 (+20.00%)")
    }

    @Test("Headline without holdings is generic")
    func emptyHeadline() {
        #expect(DigestComposer.headline(DigestPayload(periodStart: "a", periodEnd: "b")) == "Your week in Norviq")
    }

    @Test("Negative euro amounts")
    func money() {
        #expect(DigestComposer.signedMoney(-6, currency: "EUR") == "-€6.00")
        #expect(DigestComposer.signedMoney(1234.5, currency: "CHF") == "+1,234.50 CHF")
    }

    @Test("Budget keeps the two budgeted categories furthest from target")
    func budget() {
        func line(_ title: String, target: Double, actual: Double) -> BudgetCategoryDrift {
            BudgetCategoryDrift(
                id: title, title: title, targetAmount: target, actualAmount: actual,
                driftAmount: actual - target, threshold: 0.1, level: .green
            )
        }
        let dashboard = BudgetDriftDashboard(
            snapshotId: "s", monthStart: "2026-10-01", currencyCode: "EUR", revision: 1,
            totalTarget: 1000, totalActual: 1000, totalDriftAmount: 0, totalDriftPercent: nil, totalLevel: .green,
            investmentContributionTarget: 0, lostInvestmentCapital: 0,
            categories: [
                line("Groceries", target: 300, actual: 380),
                line("Dining", target: 100, actual: 90),
                line("Travel", target: 200, actual: 50),
                line("Unbudgeted", target: 0, actual: 500),
            ]
        )
        let budget = DigestFactsCollector.budget(dashboard)
        #expect(budget?.lines.map(\.title) == ["Travel", "Groceries"])
        #expect(budget?.currency == "EUR")
    }

    @Test("Inflation shows once per new reading")
    func inflationOncePerMonth() {
        let response = PersonalInflationResponse(
            country: "PT", currency: "EUR", asOf: "2026-09", periodMonths: 12,
            sampleStart: "2025-10", sampleEnd: "2026-09", personalRate: 3.214, officialRate: 2.3,
            difference: 0.914, averageMonthlySpend: 1000, estimatedAnnualImpact: nil,
            coveragePercent: 80, mappedSpend: 800, totalSpend: 1000, expenseCount: 40,
            method: "m", source: "s", components: []
        )
        #expect(DigestFactsCollector.inflation(response, previouslySeen: nil)?.personalRate == 3.21)
        #expect(DigestFactsCollector.inflation(response, previouslySeen: "2026-09") == nil)
    }

    @Test("Earnings keep held symbols, earliest date, one row each")
    func earnings() {
        let calendar = [
            EarningsItemResponse(date: "2026-10-29", hour: "amc", symbol: "aapl"),
            EarningsItemResponse(date: "2026-10-27", hour: "bmo", symbol: "MSFT"),
            EarningsItemResponse(date: "2026-10-28", hour: nil, symbol: "AAPL"),
        ]
        let rows = DigestFactsCollector.earnings(calendar, held: ["AAPL"])
        #expect(rows == [DigestEarning(symbol: "AAPL", date: "2026-10-28", hour: nil)])
    }
}

@Suite("Digest email")
struct DigestEmailRendererTests {
    private let renderer = DigestEmailRenderer(webBaseURL: "https://norviq.test", apiBaseURL: "https://api.norviq.test")
    private let digestId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private var payload: DigestPayload {
        var payload = DigestPayload(periodStart: "2026-10-19", periodEnd: "2026-10-25")
        payload.holdings = [DigestCurrencyMove(currency: "EUR", startValue: 1000, endValue: 1018, change: 18, changePercent: 1.8)]
        payload.pricedPositions = 2
        payload.totalPositions = 3
        payload.movers = [DigestMover(
            symbol: "<B&B>", currency: "EUR", shares: 1, startPrice: 10, endPrice: 28, contribution: 18, changePercent: 180
        )]
        payload.earnings = [DigestEarning(symbol: "SAP", date: "2026-10-28", hour: "bmo")]
        return payload
    }

    @Test("One-click unsubscribe headers point at the API")
    func headers() {
        let rendered = renderer.render(digestId: digestId, payload: payload, unsubscribeToken: "tok_1")
        #expect(rendered.headers["List-Unsubscribe"] == "<https://api.norviq.test/v1/digest/unsubscribe?token=tok_1>")
        #expect(rendered.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click")
        #expect(rendered.text.contains("https://norviq.test/digest/unsubscribe?token=tok_1"))
        #expect(rendered.html.contains("https://norviq.test/digest/unsubscribe?token=tok_1"))
    }

    @Test("Every section links to its place in the digest")
    func links() {
        let rendered = renderer.render(digestId: digestId, payload: payload, unsubscribeToken: "t")
        for anchor in ["holdings", "movers", "earnings"] {
            #expect(rendered.text.contains("https://norviq.test/digest/11111111-2222-3333-4444-555555555555?s=\(anchor)&src=email"))
        }
        #expect(!rendered.text.contains("s=budget"))
    }

    @Test("HTML escapes everything it did not write")
    func escaping() {
        let rendered = renderer.render(digestId: digestId, payload: payload, unsubscribeToken: "t")
        #expect(rendered.html.contains("&lt;B&amp;B&gt;"))
        #expect(!rendered.html.contains("<B&B>"))
    }

    @Test("Says when some holdings had no price")
    func unpricedNote() {
        let rendered = renderer.render(digestId: digestId, payload: payload, unsubscribeToken: "t")
        #expect(rendered.text.contains("Based on 2 of 3 holdings"))
        #expect(rendered.text.contains("SAP reports on 2026-10-28 (before open)"))
    }
}
