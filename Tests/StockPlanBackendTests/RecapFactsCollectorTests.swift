import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Recap streaks")
struct RecapStreaksTests {
    @Test func countsConsecutiveDaysIgnoringDuplicates() {
        #expect(RecapStreaks.longest(localDates: ["2026-10-01", "2026-10-02", "2026-10-02", "2026-10-04"]) == 2)
    }

    @Test func emptyIsZero() {
        #expect(RecapStreaks.longest(localDates: []) == 0)
    }

    @Test func crossesYearBoundary() {
        #expect(RecapStreaks.longest(localDates: ["2026-12-31", "2027-01-01"]) == 2)
    }

    @Test func unsortedInputAndGarbageAreHandled() {
        #expect(RecapStreaks.longest(localDates: ["2026-10-03", "not-a-date", "2026-10-01", "2026-10-02"]) == 3)
    }
}

@Suite("Recap facts collector", .serialized)
struct RecapFactsCollectorTests {
    private typealias Fx = RecapFixtures
    private let collector = RecapFactsCollector()

    /// Timestamp columns follow the user's zone; `date` columns are calendar days.
    @Test func timeZoneBoundary() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            let other = try await Fx.registerUser(app: app).userId
            try await Fx.checkIn(userId, "2026-10-20", timeZone: "America/Los_Angeles", on: db)
            let zone = try await RecapTimeZoneResolver.timeZone(for: userId, on: db)
            #expect(zone.identifier == "America/Los_Angeles")

            let account = try await Fx.account(for: userId, on: db)
            let otherAccount = try await Fx.account(for: other, on: db)
            let aapl = try await Fx.instrument(symbol: "aapl", on: db)
            // Trade dates are calendar days: Oct 31 is October, Nov 1 is November,
            // even though Nov 1 00:00 UTC is still Oct 31 in Los Angeles.
            try await Transaction(
                accountId: account, instrumentId: aapl, type: "BUY", currency: "USD", tradeDate: Fx.day("2026-10-31")
            ).save(on: db)
            try await Transaction(
                accountId: account, instrumentId: aapl, type: "SELL", currency: "USD", tradeDate: Fx.day("2026-11-01")
            ).save(on: db)
            try await Transaction(
                accountId: account, instrumentId: aapl, type: "DIVIDEND", currency: "USD", tradeDate: Fx.day("2026-10-10")
            ).save(on: db)
            try await Transaction(
                accountId: otherAccount, instrumentId: aapl, type: "BUY", currency: "USD", tradeDate: Fx.day("2026-10-15")
            ).save(on: db)

            // 2026-11-01T06:30:00Z is Oct 31, 23:30 in Los Angeles.
            try await UserBadge(
                userId: userId, badgeType: .investor, tier: .bronze, earnedAt: Fx.instant("2026-11-01T06:30:00Z")
            ).save(on: db)
            try await UserBadge(
                userId: other, badgeType: .investor, tier: .gold, earnedAt: Fx.instant("2026-10-15T12:00:00Z")
            ).save(on: db)

            // AI usage is keyed by the UTC month start, a `date`.
            let usage = AIAssistantUsage(userId: userId, monthStart: Fx.day("2026-10-01"))
            usage.requestCount = 4
            try await usage.save(on: db)
            let otherUsage = AIAssistantUsage(userId: other, monthStart: Fx.day("2026-10-01"))
            otherUsage.requestCount = 40
            try await otherUsage.save(on: db)

            let october = try await collector.collect(userId: userId, period: Fx.month("2026-10"), timeZone: zone, on: db)
            #expect(october.tradeCount == 1)
            #expect(october.buyCount == 1)
            #expect(october.sellCount == 0)
            #expect(october.tradesBySymbol == ["AAPL": 1])
            #expect(october.badgesEarned == [RecapBadge(type: "investor", tier: "bronze")])
            #expect(october.aiRequests == 4)
            #expect(october.totalBadgesEver == 1)

            let november = try await collector.collect(userId: userId, period: Fx.month("2026-11"), timeZone: zone, on: db)
            #expect(november.tradeCount == 1)
            #expect(november.sellCount == 1)
            #expect(november.badgesEarned.isEmpty)
            #expect(november.aiRequests == 0)
        }
    }

    @Test func dividendsNeverSummedAcrossCurrencies() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            let other = try await Fx.registerUser(app: app).userId
            let account = try await Fx.account(for: userId, on: db)
            let otherAccount = try await Fx.account(for: other, on: db)
            let ko = try await Fx.instrument(symbol: "KO", on: db)
            let asml = try await Fx.instrument(symbol: "ASML", currency: "EUR", on: db)
            for (instrument, amount, currency, payDate) in [
                (ko, 10.0, "USD", "2026-10-03"), (ko, 5.0, "USD", "2026-10-28"), (asml, 7.0, "EUR", "2026-10-12"),
                (ko, 99.0, "USD", "2026-11-01"),
            ] {
                try await Dividend(
                    accountId: account, instrumentId: instrument, amount: amount, currency: currency, payDate: Fx.day(payDate)
                ).save(on: db)
            }
            try await Dividend(
                accountId: otherAccount, instrumentId: ko, amount: 1000, currency: "USD", payDate: Fx.day("2026-10-03")
            ).save(on: db)

            let facts = try await collector.collect(userId: userId, period: Fx.month("2026-10"), timeZone: Fx.utc, on: db)
            #expect(facts.dividendsReceived.count == 2)
            #expect(facts.dividendsReceived.contains(RecapMoney(amount: 15, currency: "USD")))
            #expect(facts.dividendsReceived.contains(RecapMoney(amount: 7, currency: "EUR")))
            #expect(facts.dividendPayments == 3)
            #expect(facts.dividendPayers == 2)
        }
    }

    @Test func growthFirstVsLastSnapshot() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            let other = try await Fx.registerUser(app: app).userId
            let main = try await Fx.portfolioList(for: userId, on: db)
            let side = try await Fx.portfolioList(for: userId, on: db)
            let otherList = try await Fx.portfolioList(for: other, on: db)
            try await Fx.snapshot(userId, list: main, on: "2026-09-30", value: 1, db: db)
            try await Fx.snapshot(userId, list: main, on: "2026-10-02", value: 100, db: db)
            try await Fx.snapshot(userId, list: side, on: "2026-10-02", value: 50, db: db)
            try await Fx.snapshot(userId, list: main, on: "2026-10-15", value: 500, db: db)
            try await Fx.snapshot(userId, list: main, on: "2026-10-30", value: 120, db: db)
            try await Fx.snapshot(userId, list: side, on: "2026-10-30", value: 70, db: db)
            try await Fx.snapshot(userId, list: main, on: "2026-11-01", value: 9999, db: db)
            try await Fx.snapshot(other, list: otherList, on: "2026-10-02", value: 1000, db: db)
            try await Fx.snapshot(other, list: otherList, on: "2026-10-30", value: 5000, db: db)

            let facts = try await collector.collect(userId: userId, period: Fx.month("2026-10"), timeZone: Fx.utc, on: db)
            #expect(facts.growth == [RecapGrowth(currency: "USD", startValue: 150, endValue: 190)])
        }
    }

    @Test func growthNeedsTwoDistinctDates() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            let list = try await Fx.portfolioList(for: userId, on: db)
            try await Fx.snapshot(userId, list: list, on: "2026-10-02", value: 100, db: db)
            let facts = try await collector.collect(userId: userId, period: Fx.month("2026-10"), timeZone: Fx.utc, on: db)
            #expect(facts.growth.isEmpty)
        }
    }

    @Test func researchTouchesUppercase() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            let other = try await Fx.registerUser(app: app).userId
            let inOctober = Fx.instant("2026-10-10T12:00:00Z")

            let watchlist = WatchlistList(userId: userId, name: "Recap \(UUID().uuidString.prefix(8))")
            try await watchlist.save(on: db)
            let item = try WatchlistItem(userId: userId, watchlistListId: watchlist.requireID(), symbol: "aapl")
            try await item.save(on: db)
            try await Fx.backdate(table: WatchlistItem.schema, id: item.requireID(), to: inOctober, on: db)
            let note = ResearchNote(userId: userId, symbol: "AAPL", thesis: "Services keep compounding.")
            try await note.save(on: db)
            try await Fx.backdate(table: ResearchNote.schema, id: note.requireID(), to: inOctober, on: db)
            let oldNote = ResearchNote(userId: userId, symbol: "AAPL", thesis: "Old.")
            try await oldNote.save(on: db)
            try await Fx.backdate(
                table: ResearchNote.schema, id: oldNote.requireID(), to: Fx.instant("2026-09-10T12:00:00Z"), on: db
            )
            let otherNote = ResearchNote(userId: other, symbol: "AAPL", thesis: "Not mine.")
            try await otherNote.save(on: db)
            try await Fx.backdate(table: ResearchNote.schema, id: otherNote.requireID(), to: inOctober, on: db)

            let facts = try await collector.collect(userId: userId, period: Fx.month("2026-10"), timeZone: Fx.utc, on: db)
            #expect(facts.researchTouchesBySymbol == ["AAPL": 2])
            #expect(facts.notesWritten == 1)
            #expect(facts.watchlistAdded == 1)
        }
    }

    @Test func timeZoneFallback() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            let other = try await Fx.registerUser(app: app).userId
            try await Fx.checkIn(other, "2026-10-05", timeZone: "Europe/Lisbon", on: db)

            let none = try await RecapTimeZoneResolver.timeZone(for: userId, on: db)
            #expect(none == RecapTimeZoneResolver.utc)

            try await Fx.checkIn(userId, "2026-10-01", timeZone: "Europe/Lisbon", on: db)
            try await Fx.checkIn(userId, "2026-10-02", timeZone: "Mars/Base", on: db)
            let invalid = try await RecapTimeZoneResolver.timeZone(for: userId, on: db)
            #expect(invalid == RecapTimeZoneResolver.utc)
        }
    }

    @Test func activityGamificationAndGoals() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            let other = try await Fx.registerUser(app: app).userId
            let september = ["2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30"]
            let october = ["2026-10-01", "2026-10-02", "2026-10-15", "2026-10-16", "2026-10-31"]
            for localDate in september + october {
                try await Fx.checkIn(userId, localDate, on: db)
            }
            try await Fx.checkIn(other, "2026-10-03", on: db)

            let inOctober = Fx.instant("2026-10-10T12:00:00Z")
            let xp = GamificationXPEvent(userId: userId, type: .checkIn, points: 15, dedupeKey: "recap-a")
            try await xp.save(on: db)
            try await Fx.backdate(table: GamificationXPEvent.schema, id: xp.requireID(), to: inOctober, on: db)
            let oldXP = GamificationXPEvent(userId: userId, type: .checkIn, points: 500, dedupeKey: "recap-b")
            try await oldXP.save(on: db)
            try await Fx.backdate(
                table: GamificationXPEvent.schema, id: oldXP.requireID(), to: Fx.instant("2026-09-10T12:00:00Z"), on: db
            )
            let otherXP = GamificationXPEvent(userId: other, type: .checkIn, points: 70, dedupeKey: "recap-c")
            try await otherXP.save(on: db)
            try await Fx.backdate(table: GamificationXPEvent.schema, id: otherXP.requireID(), to: inOctober, on: db)

            try await UserBadge(
                userId: userId, badgeType: .investor, tier: .bronze, earnedAt: Fx.instant("2026-09-01T12:00:00Z")
            ).save(on: db)

            let target = Target(
                userId: userId, symbol: "msft", scenario: "base", targetPrice: 500,
                alertTriggeredAt: Fx.instant("2026-10-20T15:00:00Z")
            )
            try await target.save(on: db)
            try await Fx.backdate(table: Target.schema, id: target.requireID(), to: Fx.instant("2026-08-01T12:00:00Z"), on: db)
            let newTarget = Target(userId: userId, symbol: "nvda", scenario: "bull", targetPrice: 300)
            try await newTarget.save(on: db)
            try await Fx.backdate(table: Target.schema, id: newTarget.requireID(), to: inOctober, on: db)

            let list = try await Fx.portfolioList(for: userId, on: db)
            let goal = FinancialGoalModel(
                userId: userId, portfolioListId: list, name: "House", targetAmount: 50000,
                targetDate: Fx.day("2030-01-01"), baseCurrency: "EUR", monthlyContribution: 500,
                annualContributionGrowth: 0, inflationAssumption: 0.02
            )
            try await goal.save(on: db)
            for (amount, at) in [(200.0, "2026-10-05T10:00:00Z"), (300.0, "2026-10-25T10:00:00Z"), (999.0, "2026-11-02T10:00:00Z")] {
                try await GoalContributionModel(
                    goalId: goal.requireID(), userId: userId, amount: amount, occurredAt: Fx.instant(at), note: nil
                ).save(on: db)
            }

            let facts = try await collector.collect(userId: userId, period: Fx.month("2026-10"), timeZone: Fx.utc, on: db)
            #expect(facts.activeDays == 5)
            #expect(facts.activeDaysFirstHalf == 3)
            #expect(facts.activeDaysSecondHalf == 2)
            #expect(facts.longestStreakDays == 2)
            #expect(facts.bestStreakEverDays == 6)
            #expect(facts.xpEarned == 15)
            #expect(facts.badgesEarned.isEmpty)
            #expect(facts.totalBadgesEver == 1)
            #expect(facts.targetsSet == 1)
            #expect(facts.targetsHit == 1)
            #expect(facts.researchTouchesBySymbol == ["NVDA": 1])
            #expect(facts.goalContributions == [RecapMoney(amount: 500, currency: "EUR")])
            #expect(facts.goalContributionCount == 2)
            #expect(facts.pilotFollows == 0)
            #expect(facts.boardPosts == 0)
            #expect(facts.boardComments == 0)
            #expect(facts.expensesRecorded == 0)
            #expect(facts.hasAnyActivity)

            let year = try await collector.collect(
                userId: userId, period: #require(RecapPeriod.parse(kind: "year", key: "2026")), timeZone: Fx.utc, on: db
            )
            #expect(year.activeDays == 9)
            #expect(year.activeDaysFirstHalf == 0)
            #expect(year.activeDaysSecondHalf == 9)
            #expect(year.longestStreakDays == 6)
            #expect(year.goalContributionCount == 3)
        }
    }

    @Test func quietUserHasNoActivity() async throws {
        try await Fx.withUser { app, _, userId in
            let facts = try await collector.collect(
                userId: userId, period: Fx.month("2026-10"), timeZone: Fx.utc, on: app.db
            )
            #expect(facts == RecapFacts())
            #expect(!facts.hasAnyActivity)
        }
    }
}
