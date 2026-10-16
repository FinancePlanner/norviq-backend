import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Recap deck builder")
struct RecapDeckBuilderTests {
    private let october = RecapPeriod(kind: .month, year: 2026, month: 10)

    private enum SlideType: Equatable {
        case intro, streak, topTickers, trades, research, growth, dividends, goals, badges, personality, missedYou, outro
    }

    private func types(_ deck: RecapDeck) -> [SlideType] {
        deck.slides.map { slide in
            switch slide {
            case .intro: .intro
            case .streak: .streak
            case .topTickers: .topTickers
            case .trades: .trades
            case .research: .research
            case .growth: .growth
            case .dividends: .dividends
            case .goals: .goals
            case .badges: .badges
            case .personality: .personality
            case .missedYou: .missedYou
            case .outro: .outro
            }
        }
    }

    private func richFacts(activeDays: Int = 20) -> RecapFacts {
        var f = RecapFacts()
        f.activeDays = activeDays
        f.longestStreakDays = 5
        f.researchTouchesBySymbol = ["AAPL": 3, "MSFT": 2, "NVDA": 1]
        f.tradeCount = 3
        f.buyCount = 2
        f.sellCount = 1
        f.tradesBySymbol = ["AAPL": 2, "MSFT": 1]
        f.notesWritten = 2
        f.growth = [RecapGrowth(currency: "USD", startValue: 100, endValue: 120)]
        f.dividendsReceived = [RecapMoney(amount: 5, currency: "USD")]
        f.dividendPayments = 1
        f.dividendPayers = 1
        f.goalContributions = [RecapMoney(amount: 50, currency: "USD")]
        f.goalContributionCount = 1
        f.badgesEarned = [RecapBadge(type: "streak", tier: "bronze")]
        return f
    }

    @Test func missedYou() {
        let deck = RecapDeckBuilder.build(
            facts: RecapFacts(bestStreakEverDays: 9, totalBadgesEver: 2), period: october
        )
        #expect(types(deck) == [.intro, .missedYou, .outro])
        #expect(deck.isMissedYou == true)
        #expect(deck.archetype == nil)
        #expect(deck.isFirstChapter == false)
        #expect(deck.slides[1] == .missedYou(RecapMissedYouSlide(bestStreakDays: 9, totalBadges: 2)))
        #expect(deck.slides[2] == .outro(RecapOutroSlide(isFirstChapter: false, nextPeriodLabel: "November 2026")))
    }

    /// Activity with no eligible middle slide (only XP and AI requests) gets
    /// the missed-you deck, not an empty first chapter.
    @Test func activityWithoutEligibleSlideIsMissedYou() {
        let facts = RecapFacts(xpEarned: 50, aiRequests: 3, bestStreakEverDays: 4, totalBadgesEver: 1)
        #expect(facts.hasAnyActivity)
        let deck = RecapDeckBuilder.build(facts: facts, period: october)
        #expect(types(deck) == [.intro, .missedYou, .outro])
        #expect(deck.isMissedYou == true)
        #expect(deck.isFirstChapter == false)
        #expect(deck.archetype == nil)
        #expect(deck.slides[1] == .missedYou(RecapMissedYouSlide(bestStreakDays: 4, totalBadges: 1)))
    }

    struct ActivityRow: Sendable {
        let name: String
        let facts: RecapFacts
        let expected: Bool
    }

    static let activityRows: [ActivityRow] = [
        ActivityRow(name: "empty", facts: RecapFacts(), expected: false),
        ActivityRow(
            name: "lifetime fields only", facts: RecapFacts(bestStreakEverDays: 30, totalBadgesEver: 8), expected: false
        ),
        ActivityRow(name: "active day", facts: RecapFacts(activeDays: 1), expected: true),
        ActivityRow(name: "trade", facts: RecapFacts(tradeCount: 1), expected: true),
        ActivityRow(name: "research touch", facts: RecapFacts(researchTouchesBySymbol: ["AAPL": 1]), expected: true),
        ActivityRow(name: "target hit", facts: RecapFacts(targetsHit: 1), expected: true),
        ActivityRow(name: "dividend", facts: RecapFacts(dividendPayments: 1), expected: true),
        ActivityRow(
            name: "badge", facts: RecapFacts(badgesEarned: [RecapBadge(type: "streak", tier: "bronze")]), expected: true
        ),
        ActivityRow(name: "xp", facts: RecapFacts(xpEarned: 10), expected: true),
        ActivityRow(name: "pilot follow", facts: RecapFacts(pilotFollows: 1), expected: true),
        ActivityRow(name: "board comment", facts: RecapFacts(boardComments: 1), expected: true),
        ActivityRow(name: "ai request", facts: RecapFacts(aiRequests: 1), expected: true),
        ActivityRow(name: "expense", facts: RecapFacts(expensesRecorded: 1), expected: true),
    ]

    @Test(arguments: activityRows)
    func hasAnyActivityTable(row: ActivityRow) {
        #expect(row.facts.hasAnyActivity == row.expected, "\(row.name)")
    }

    @Test func fullDeckOrderAndPersonality() {
        let deck = RecapDeckBuilder.build(facts: richFacts(), period: october)
        #expect(types(deck) == [
            .intro, .streak, .topTickers, .trades, .research, .growth, .dividends, .goals, .badges,
            .personality, .outro,
        ])
        #expect(deck.archetype != nil)
        #expect(deck.isFirstChapter == false)
        #expect(deck.isMissedYou == false)
        #expect(deck.schemaVersion == 1)
        #expect(deck.periodLabel == "October 2026")
        #expect(deck.key == "2026-10")
        #expect(deck.kind == .month)
        #expect(deck.slides.first == .intro(RecapIntroSlide(periodLabel: "October 2026", activeDays: 20)))
        guard case let .trades(trades) = deck.slides[3] else {
            Issue.record("expected trades")
            return
        }
        #expect(trades.mostTradedSymbol == "AAPL")
    }

    @Test func firstChapterWhenFewSlides() {
        var f = RecapFacts()
        f.activeDays = 20
        f.longestStreakDays = 4
        f.tradeCount = 1
        f.buyCount = 1
        f.tradesBySymbol = ["AAPL": 1]
        let deck = RecapDeckBuilder.build(facts: f, period: october)
        #expect(types(deck) == [.intro, .streak, .trades, .outro])
        #expect(deck.isFirstChapter == true)
        #expect(deck.archetype == nil)
        #expect(deck.slides.last == .outro(RecapOutroSlide(isFirstChapter: true, nextPeriodLabel: "November 2026")))
    }

    @Test func firstChapterWhenFewDays() {
        let deck = RecapDeckBuilder.build(facts: richFacts(activeDays: 6), period: october)
        #expect(types(deck) == [.intro, .streak, .topTickers, .outro])
        #expect(deck.isFirstChapter == true)
        #expect(deck.archetype == nil)
    }

    @Test func topTickersCapAndTieBreak() {
        var f = richFacts()
        f.researchTouchesBySymbol = [
            "ZZZ": 1, "MSFT": 4, "AAPL": 4, "NVDA": 6, "TSLA": 3, "AMZN": 2, "GOOG": 1,
        ]
        let deck = RecapDeckBuilder.build(facts: f, period: october)
        guard case let .topTickers(slide) = deck.slides[2] else {
            Issue.record("expected topTickers")
            return
        }
        #expect(slide.tickers.count == 5)
        #expect(slide.tickers.map(\.symbol) == ["NVDA", "AAPL", "MSFT", "TSLA", "AMZN"])
    }

    @Test func nextLabel() {
        let december = RecapPeriod(kind: .month, year: 2026, month: 12)
        let deck = RecapDeckBuilder.build(facts: richFacts(), period: december)
        guard case let .outro(outro) = deck.slides.last else {
            Issue.record("expected outro")
            return
        }
        #expect(outro.nextPeriodLabel == "January 2027")
    }
}
