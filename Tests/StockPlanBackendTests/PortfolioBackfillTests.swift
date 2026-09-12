import Fluent
import Foundation
import SQLKit
@testable import StockPlanBackend
import Testing
import Vapor

/// Tests for reconstructing portfolio history from stored price bars.
///
/// Backfill is approximate by construction, so what matters is that its
/// approximations are the ones we chose: positions appear when they were
/// bought, observed rows are never overwritten, splits do not show up as
/// crashes, and thin price coverage produces gaps rather than wrong numbers.
@Suite("PortfolioBackfill", .serialized)
struct PortfolioBackfillTests {
    /// 2024-03-15T12:00:00Z, a Friday. Bars are written for the ten weekdays
    /// ending here.
    private static let friday = Date(timeIntervalSince1970: 1_710_504_000)

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    // MARK: - Fixtures

    private func makeUser(on db: any Database) async throws -> UUID {
        let id = UUID()
        let suffix = id.uuidString.prefix(8).lowercased()
        try await User(
            id: id,
            email: "backfill_\(suffix)@example.com",
            passwordHash: "not-a-real-hash"
        ).create(on: db)
        return id
    }

    private func makeList(
        userId: UUID,
        name: String = "Test portfolio",
        on db: any Database
    ) async throws -> PortfolioList {
        let list = PortfolioList(id: UUID(), userId: userId, name: name)
        try await list.create(on: db)
        return list
    }

    private func addStock(
        userId: UUID,
        listId: UUID,
        symbol: String,
        shares: Double,
        buyPrice: Double,
        buyDate: Date,
        on db: any Database
    ) async throws {
        try await Stock(
            userId: userId,
            portfolioListId: listId,
            symbol: symbol,
            shares: shares,
            buyPrice: buyPrice,
            buyDate: buyDate
        ).create(on: db)
    }

    private func addBar(
        symbol: String,
        day: Date,
        close: Double,
        adjustedClose: Double? = nil,
        on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        let date = PortfolioSnapshotValuator.startOfDay(day)
        let adjusted = adjustedClose ?? close
        try await sql.raw("""
        INSERT INTO market_price_bars
            (instrument_key, date, open, high, low, close, adjusted_close, currency, provider)
        VALUES (\(bind: symbol.uppercased()), \(bind: date), \(bind: close), \(bind: close),
                \(bind: close), \(bind: close), \(bind: adjusted), \(bind: "USD"), \(bind: "test"))
        ON CONFLICT (instrument_key, date) DO UPDATE SET
            close = EXCLUDED.close, adjusted_close = EXCLUDED.adjusted_close
        """).run()
    }

    /// Bars for `count` consecutive days ending on `endingOn`, at a flat price.
    private func addDailyBars(
        symbol: String,
        endingOn: Date,
        count: Int,
        close: Double,
        on db: any Database
    ) async throws {
        for offset in 0 ..< count {
            let day = PortfolioSnapshotValuator.addDays(endingOn, days: -offset)
            try await addBar(symbol: symbol, day: day, close: close, on: db)
        }
    }

    private func snapshots(
        userId: UUID,
        on db: any Database
    ) async throws -> [PortfolioValueSnapshot] {
        try await PortfolioValueSnapshot.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$capturedOn)
            .all()
    }

    // MARK: - Reconstruction

    @Test("Writes one backfilled row per priced day")
    func writesRowPerPricedDay() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            let boughtLongAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150,
                buyDate: boughtLongAgo, on: app.db
            )
            try await addDailyBars(
                symbol: "AAPL", endingOn: Self.friday, count: 5, close: 200, on: app.db
            )

            let report = try await PortfolioBackfillCommand().backfill(
                userId: userId, days: 30, dryRun: false, now: Self.friday, on: app.db
            )

            #expect(report.written == 5)

            let rows = try await snapshots(userId: userId, on: app.db)
            #expect(rows.count == 5)
            #expect(rows.allSatisfy { $0.source == PortfolioValueSnapshot.Source.backfill.rawValue })
            #expect(rows.allSatisfy { $0.marketValue == 2000 })
        }
    }

    /// The filter that makes a reconstructed curve grow as positions were added,
    /// instead of projecting today's whole portfolio back through time.
    @Test("A position is absent from days before it was bought")
    func positionsAppearWhenBought() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)

            let longAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)
            // Bought two days before the window's last day.
            let recently = PortfolioSnapshotValuator.addDays(Self.friday, days: -2)

            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: longAgo, on: app.db
            )
            try await addStock(
                userId: userId, listId: listId,
                symbol: "MSFT", shares: 5, buyPrice: 300, buyDate: recently, on: app.db
            )
            try await addDailyBars(
                symbol: "AAPL", endingOn: Self.friday, count: 5, close: 200, on: app.db
            )
            try await addDailyBars(
                symbol: "MSFT", endingOn: Self.friday, count: 5, close: 400, on: app.db
            )

            try await PortfolioBackfillCommand().backfill(
                userId: userId, days: 30, dryRun: false, now: Self.friday, on: app.db
            )

            let rows = try await snapshots(userId: userId, on: app.db)
            #expect(rows.count == 5)

            // Earliest days: AAPL only.
            let earliest = try #require(rows.first)
            #expect(earliest.positionCount == 1)
            #expect(earliest.marketValue == 2000)

            // Latest day: both held.
            let latest = try #require(rows.last)
            #expect(latest.positionCount == 2)
            #expect(latest.marketValue == 4000)
        }
    }

    /// Adjusted closes, not raw ones. A 2:1 split halves the raw close overnight;
    /// using it would record a 50% crash that never happened.
    @Test("Split-adjusted closes are used, so a split is not a crash")
    func usesAdjustedCloses() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            let longAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: longAgo, on: app.db
            )

            // Two days, either side of a 2:1 split. The raw close halves; the
            // adjusted series is continuous at 200.
            let dayBefore = PortfolioSnapshotValuator.addDays(Self.friday, days: -1)
            try await addBar(
                symbol: "AAPL", day: dayBefore, close: 400, adjustedClose: 200, on: app.db
            )
            try await addBar(
                symbol: "AAPL", day: Self.friday, close: 200, adjustedClose: 200, on: app.db
            )

            try await PortfolioBackfillCommand().backfill(
                userId: userId, days: 30, dryRun: false, now: Self.friday, on: app.db
            )

            let rows = try await snapshots(userId: userId, on: app.db)
            #expect(rows.count == 2)
            // Flat across the split, not down 50%.
            #expect(rows.map(\.marketValue) == [2000, 2000])
        }
    }

    // MARK: - Never overwriting observed truth

    @Test("A day already captured live is left alone")
    func doesNotOverwriteLiveRows() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            let longAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: longAgo, on: app.db
            )
            try await addDailyBars(
                symbol: "AAPL", endingOn: Self.friday, count: 3, close: 200, on: app.db
            )

            // A live row already exists for the final day, with a different value.
            try await PortfolioValueSnapshot(
                userId: userId,
                portfolioListId: listId,
                capturedOn: PortfolioSnapshotValuator.startOfDay(Self.friday),
                currency: "USD",
                marketValue: 9999,
                costBasis: 1500,
                cashBalance: 0,
                positionCount: 1,
                source: .live,
                pricedSymbols: 1,
                missingSymbols: 0
            ).create(on: app.db)

            let report = try await PortfolioBackfillCommand().backfill(
                userId: userId, days: 30, dryRun: false, now: Self.friday, on: app.db
            )

            #expect(report.skippedExisting == 1)
            #expect(report.written == 2)

            let rows = try await snapshots(userId: userId, on: app.db)
            let live = try #require(rows.last)
            #expect(live.marketValue == 9999, "the observed row must survive")
            #expect(live.source == PortfolioValueSnapshot.Source.live.rawValue)
        }
    }

    @Test("Running twice changes nothing the second time")
    func isRerunnable() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            let longAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: longAgo, on: app.db
            )
            try await addDailyBars(
                symbol: "AAPL", endingOn: Self.friday, count: 4, close: 200, on: app.db
            )

            let command = PortfolioBackfillCommand()
            let first = try await command.backfill(
                userId: userId, days: 30, dryRun: false, now: Self.friday, on: app.db
            )
            let second = try await command.backfill(
                userId: userId, days: 30, dryRun: false, now: Self.friday, on: app.db
            )

            #expect(first.written == 4)
            #expect(second.written == 0)
            #expect(second.skippedExisting == 4)
            #expect(try await snapshots(userId: userId, on: app.db).count == 4)
        }
    }

    // MARK: - Strictness carries over

    /// The same rule as the live job: thin price coverage yields gaps, not
    /// silently low values.
    @Test("A day where a held symbol has no price is skipped")
    func skipsIncompletelyPricedDays() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            let longAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: longAgo, on: app.db
            )
            try await addStock(
                userId: userId, listId: listId,
                symbol: "NVDA", shares: 4, buyPrice: 500, buyDate: longAgo, on: app.db
            )

            // AAPL priced for three days; NVDA only for the most recent one.
            try await addDailyBars(
                symbol: "AAPL", endingOn: Self.friday, count: 3, close: 200, on: app.db
            )
            try await addBar(symbol: "NVDA", day: Self.friday, close: 600, on: app.db)

            let report = try await PortfolioBackfillCommand().backfill(
                userId: userId, days: 30, dryRun: false, now: Self.friday, on: app.db
            )

            #expect(report.written == 1)
            #expect(report.skippedIncomplete == 2)

            let rows = try await snapshots(userId: userId, on: app.db)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.marketValue == 4400)
            #expect(row.missingSymbols == 0)
        }
    }

    // MARK: - Dry run

    @Test("A dry run reports what it would write and writes nothing")
    func dryRunWritesNothing() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            let longAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: longAgo, on: app.db
            )
            try await addDailyBars(
                symbol: "AAPL", endingOn: Self.friday, count: 3, close: 200, on: app.db
            )

            let report = try await PortfolioBackfillCommand().backfill(
                userId: userId, days: 30, dryRun: true, now: Self.friday, on: app.db
            )

            #expect(report.written == 3)
            #expect(try await snapshots(userId: userId, on: app.db).isEmpty)
        }
    }

    // MARK: - Scoping

    @Test("The window bounds how far back reconstruction reaches")
    func windowBoundsReconstruction() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            let longAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: longAgo, on: app.db
            )
            try await addDailyBars(
                symbol: "AAPL", endingOn: Self.friday, count: 10, close: 200, on: app.db
            )

            let report = try await PortfolioBackfillCommand().backfill(
                userId: userId, days: 3, dryRun: false, now: Self.friday, on: app.db
            )

            // The window covers today and the three days before it.
            #expect(report.written == 4)
        }
    }

    @Test("Another user's portfolios are untouched")
    func scopesToRequestedUser() async throws {
        try await withApp { app in
            let target = try await makeUser(on: app.db)
            let other = try await makeUser(on: app.db)
            let longAgo = PortfolioSnapshotValuator.addDays(Self.friday, days: -60)

            for userId in [target, other] {
                let list = try await makeList(userId: userId, on: app.db)
                try await addStock(
                    userId: userId, listId: #require(list.id),
                    symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: longAgo, on: app.db
                )
            }
            try await addDailyBars(
                symbol: "AAPL", endingOn: Self.friday, count: 3, close: 200, on: app.db
            )

            try await PortfolioBackfillCommand().backfill(
                userId: target, days: 30, dryRun: false, now: Self.friday, on: app.db
            )

            #expect(try await snapshots(userId: target, on: app.db).count == 3)
            #expect(try await snapshots(userId: other, on: app.db).isEmpty)
        }
    }
}
