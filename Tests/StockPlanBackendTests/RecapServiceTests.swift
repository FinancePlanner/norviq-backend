import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Recap service", .serialized)
struct RecapServiceTests {
    private typealias Fx = RecapFixtures

    private static func service(yearly: Bool = false, enabled: Bool = true) -> RecapService {
        RecapService(
            repository: DatabaseRecapRepository(),
            config: RecapConfig(enabled: enabled, yearlyEnabled: yearly)
        )
    }

    /// Forces the user's signup well before every period under test.
    private static func signedUp(_ userId: UUID, on date: String = "2026-01-01", db: any Database) async throws {
        try await Fx.backdate(table: "users", id: userId, to: Fx.day(date), on: db)
    }

    private static func buy(_ userId: UUID, on tradeDate: String, db: any Database) async throws {
        let account = try await Fx.account(for: userId, on: db)
        let msft = try await Fx.instrument(symbol: "MSFT", on: db)
        try await Transaction(
            accountId: account, instrumentId: msft, type: TransactionType.buy.rawValue,
            currency: "USD", tradeDate: Fx.day(tradeDate)
        ).save(on: db)
    }

    private static func tradeCount(_ deck: RecapDeck) -> Int? {
        for slide in deck.slides {
            if case let .trades(trades) = slide {
                return trades.tradeCount
            }
        }
        return nil
    }

    @Test func generatesOnceAndFreezes() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            try await Self.signedUp(userId, db: db)
            try await Self.buy(userId, on: "2026-10-05", db: db)
            let service = Self.service()
            let now = Fx.instant("2026-11-02T12:00:00Z")

            let first = try #require(try await service.recap(userId: userId, period: Fx.month("2026-10"), now: now, on: db))
            #expect(Self.tradeCount(first.deck) == 1)

            try await Self.buy(userId, on: "2026-10-12", db: db)
            let second = try #require(try await service.recap(userId: userId, period: Fx.month("2026-10"), now: now, on: db))
            #expect(second.id == first.id)
            #expect(Self.tradeCount(second.deck) == 1)
            #expect(second.deck == first.deck)
        }
    }

    @Test func concurrentFirstOpenMakesOneRow() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            try await Self.signedUp(userId, db: db)
            try await Self.buy(userId, on: "2026-10-05", db: db)
            let service = Self.service()
            let now = Fx.instant("2026-11-02T12:00:00Z")
            let period = Fx.month("2026-10")

            let ids = try await withThrowingTaskGroup(of: UUID?.self) { group in
                for _ in 0 ..< 2 {
                    group.addTask {
                        try await service.recap(userId: userId, period: period, now: now, on: db)?.id
                    }
                }
                var ids: [UUID?] = []
                for try await id in group {
                    ids.append(id)
                }
                return ids
            }

            #expect(ids.count == 2)
            #expect(ids[0] != nil)
            #expect(ids[0] == ids[1])
            let rows = try await RecapRecord.query(on: db).filter(\.$userId == userId).count()
            #expect(rows == 1)
        }
    }

    /// The unique-violation path itself: a second insert for the same user and
    /// period returns the row that is already there.
    @Test func insertOrFetchReturnsExistingOnDuplicate() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            let repository = DatabaseRecapRepository()
            let deck = RecapDeckBuilder.build(facts: RecapFacts(), period: Fx.month("2026-10"))
            let now = Fx.instant("2026-11-02T12:00:00Z")

            let first = try await repository.insertOrFetch(RecapRecord(userId: userId, deck: deck, generatedAt: now), on: db)
            let second = try await repository.insertOrFetch(
                RecapRecord(userId: userId, deck: deck, generatedAt: now.addingTimeInterval(60)), on: db
            )
            let firstId = try first.requireID()
            let secondId = try second.requireID()
            #expect(secondId == firstId)
            #expect(second.generatedAt == first.generatedAt)
            let rows = try await RecapRecord.query(on: db).filter(\.$userId == userId).count()
            #expect(rows == 1)
        }
    }

    @Test func unavailableReturnsNil() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            try await Self.signedUp(userId, db: db)
            let response = try await Self.service().recap(
                userId: userId, period: Fx.month("2026-11"), now: Fx.instant("2026-11-20T12:00:00Z"), on: db
            )
            #expect(response == nil)
            let rows = try await RecapRecord.query(on: db).filter(\.$userId == userId).count()
            #expect(rows == 0)
        }
    }

    @Test func disabledReturnsNil() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            try await Self.signedUp(userId, db: db)
            let response = try await Self.service(enabled: false).recap(
                userId: userId, period: Fx.month("2026-10"), now: Fx.instant("2026-11-02T12:00:00Z"), on: db
            )
            #expect(response == nil)
            let rows = try await RecapRecord.query(on: db).filter(\.$userId == userId).count()
            #expect(rows == 0)
        }
    }

    @Test func yearlyNeedsFlag() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            try await Self.signedUp(userId, db: db)
            let year = try #require(RecapPeriod.parse(kind: "year", key: "2026"))
            let now = Fx.instant("2027-01-02T12:00:00Z")

            let off = try await Self.service(yearly: false).recap(userId: userId, period: year, now: now, on: db)
            #expect(off == nil)

            let on = try #require(try await Self.service(yearly: true).recap(userId: userId, period: year, now: now, on: db))
            #expect(on.deck.kind == .year)
            #expect(on.deck.key == "2026")
        }
    }

    @Test func listShowsUngeneratedLastMonth() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            try await Self.signedUp(userId, on: "2026-09-01", db: db)

            let list = try await Self.service().list(userId: userId, now: Fx.instant("2026-11-02T12:00:00Z"), on: db)

            let expected = RecapSummary(
                kind: .month, key: "2026-10", periodLabel: "October 2026",
                id: nil, generated: false, openedAt: nil, completedAt: nil
            )
            #expect(list.recaps.contains(expected))
            let rows = try await RecapRecord.query(on: db).filter(\.$userId == userId).count()
            #expect(rows == 0)
        }
    }

    @Test func listShowsStoredRecapOnceAndYearOnlyWithFlag() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            try await Self.signedUp(userId, db: db)
            let now = Fx.instant("2027-01-02T12:00:00Z")
            let stored = try #require(try await Self.service().recap(
                userId: userId, period: Fx.month("2026-12"), now: now, on: db
            ))

            let monthly = try await Self.service().list(userId: userId, now: now, on: db)
            #expect(monthly.recaps.count == 1)
            #expect(monthly.recaps.first?.id == stored.id)
            #expect(monthly.recaps.first?.generated == true)

            let yearly = try await Self.service(yearly: true).list(userId: userId, now: now, on: db)
            let year = yearly.recaps.first { $0.kind == .year }
            #expect(year?.key == "2026")
            #expect(year?.generated == false)
            #expect(yearly.recaps.count == 2)
        }
    }

    @Test func markOpenedOwnership() async throws {
        try await Fx.withUser { app, _, userId in
            let db = app.db
            try await Self.signedUp(userId, db: db)
            let other = try await Fx.registerUser(app: app).userId
            let service = Self.service()
            let now = Fx.instant("2026-11-02T12:00:00Z")
            let recap = try #require(try await service.recap(userId: userId, period: Fx.month("2026-10"), now: now, on: db))

            let foreign = try await service.markOpened(id: recap.id, userId: other, now: now, on: db)
            #expect(foreign == false)
            let unknown = try await service.markOpened(id: UUID(), userId: userId, now: now, on: db)
            #expect(unknown == false)

            let firstOpen = Fx.instant("2026-11-02T13:00:00Z")
            let opened = try await service.markOpened(id: recap.id, userId: userId, now: firstOpen, on: db)
            #expect(opened == true)
            let reopened = try await service.markOpened(
                id: recap.id, userId: userId, now: Fx.instant("2026-11-03T09:00:00Z"), on: db
            )
            #expect(reopened == true)

            let completed = try await service.markCompleted(id: recap.id, userId: userId, now: firstOpen, on: db)
            #expect(completed == true)

            let after = try #require(try await service.recap(userId: userId, period: Fx.month("2026-10"), now: now, on: db))
            #expect(after.openedAt == firstOpen)
            #expect(after.completedAt == firstOpen)
        }
    }
}
