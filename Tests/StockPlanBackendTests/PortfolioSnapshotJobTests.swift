import Fluent
import Foundation
import SQLKit
@testable import StockPlanBackend
import Testing
import Vapor

/// Tests for the daily capture of portfolio value history.
///
/// The behaviours that matter here are all about what the job *refuses* to
/// write. A wrong row is worse than an absent one: an absent day renders as a
/// gap, a wrong day renders as a move that never happened.
@Suite("PortfolioSnapshotJob", .serialized)
struct PortfolioSnapshotJobTests {
    // 2024-03-15T12:00:00Z, a Friday.
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

    /// `portfolio_lists.user_id` is a foreign key onto `users`, so a portfolio
    /// needs a real owner.
    private func makeUser(on db: any Database) async throws -> UUID {
        let id = UUID()
        let suffix = id.uuidString.prefix(8).lowercased()
        try await User(
            id: id,
            email: "snapshot_\(suffix)@example.com",
            passwordHash: "not-a-real-hash"
        ).create(on: db)
        return id
    }

    /// Names are unique per user, so each list gets its own.
    private func makeList(
        userId: UUID,
        name: String = "Test portfolio",
        mode: String = "actual",
        on db: any Database
    ) async throws -> PortfolioList {
        let list = PortfolioList(
            id: UUID(),
            userId: userId,
            name: name,
            mode: mode
        )
        try await list.create(on: db)
        return list
    }

    private func addStock(
        userId: UUID,
        listId: UUID,
        symbol: String,
        shares: Double,
        buyPrice: Double,
        buyDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
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

    /// Writes a bar directly. `MarketPriceBarRepository.upsert` takes provider
    /// DTOs; here the point is only that a priced day exists.
    private func addBar(
        symbol: String,
        day: Date,
        close: Double,
        on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        let date = PortfolioSnapshotValuator.startOfDay(day)
        try await sql.raw("""
        INSERT INTO market_price_bars
            (instrument_key, date, open, high, low, close, adjusted_close, currency, provider)
        VALUES (\(bind: symbol.uppercased()), \(bind: date), \(bind: close), \(bind: close),
                \(bind: close), \(bind: close), \(bind: close), \(bind: "USD"), \(bind: "test"))
        ON CONFLICT (instrument_key, date) DO UPDATE SET close = EXCLUDED.close
        """).run()
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

    // MARK: - The happy path

    @Test("Captures one row for a fully priced portfolio on a trading day")
    func capturesFullyPricedPortfolio() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, on: app.db
            )
            try await addBar(symbol: "AAPL", day: Self.friday, close: 200, on: app.db)

            let job = PortfolioSnapshotJob()
            let outcome = try await job.capture(list: list, now: Self.friday, on: app.db)

            #expect(outcome == .captured)

            let rows = try await snapshots(userId: userId, on: app.db)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.marketValue == 2000)
            #expect(row.costBasis == 1500)
            #expect(row.positionCount == 1)
            #expect(row.pricedSymbols == 1)
            #expect(row.missingSymbols == 0)
            #expect(row.source == PortfolioValueSnapshot.Source.live.rawValue)
        }
    }

    // MARK: - Idempotency

    /// The job ticks hourly but must leave one row per day. Without this, a pod
    /// restarting through the day would manufacture intraday "history" and the
    /// day-over-day delta would compare two points from the same afternoon.
    @Test("A second run on the same day writes nothing")
    func secondRunSameDayIsNoOp() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, on: app.db
            )
            try await addBar(symbol: "AAPL", day: Self.friday, close: 200, on: app.db)

            let job = PortfolioSnapshotJob()
            #expect(try await job.capture(list: list, now: Self.friday, on: app.db) == .captured)

            // Same day, four hours later: still the same calendar day.
            let later = Self.friday.addingTimeInterval(4 * 3600)
            #expect(try await job.capture(list: list, now: later, on: app.db) == .alreadyCaptured)

            let rows = try await snapshots(userId: userId, on: app.db)
            #expect(rows.count == 1)
        }
    }

    @Test("The unique constraint rejects a duplicate day outright")
    func uniqueConstraintHolds() async throws {
        try await withApp { app in
            let userId = UUID()
            let listId = UUID()
            let day = PortfolioSnapshotValuator.startOfDay(Self.friday)

            func makeSnapshot() -> PortfolioValueSnapshot {
                PortfolioValueSnapshot(
                    userId: userId,
                    portfolioListId: listId,
                    capturedOn: day,
                    currency: "USD",
                    marketValue: 1000,
                    costBasis: 900,
                    cashBalance: 0,
                    positionCount: 1,
                    source: .live,
                    pricedSymbols: 1,
                    missingSymbols: 0
                )
            }

            try await makeSnapshot().create(on: app.db)

            var rejected = false
            do {
                try await makeSnapshot().create(on: app.db)
            } catch {
                rejected = true
            }
            #expect(rejected, "a second row for the same user/list/day must be rejected")
        }
    }

    // MARK: - What the job refuses to write

    /// The whole point of `missingSymbols`. Writing a portfolio's value with
    /// three of twelve symbols unpriced records a number that is silently low,
    /// and the chart shows a crash that never happened.
    @Test("A portfolio with an unpriced symbol is not captured at all")
    func incompletePricingIsNotCaptured() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, on: app.db
            )
            try await addStock(
                userId: userId, listId: listId,
                symbol: "NVDA", shares: 4, buyPrice: 500, on: app.db
            )
            // AAPL trades; NVDA has no price at all.
            try await addBar(symbol: "AAPL", day: Self.friday, close: 200, on: app.db)

            let job = PortfolioSnapshotJob()
            let outcome = try await job.capture(list: list, now: Self.friday, on: app.db)

            #expect(outcome == .incompletePricing(missing: 1))
            #expect(try await snapshots(userId: userId, on: app.db).isEmpty)
        }
    }

    /// A weekend must leave a gap, not a carried-forward duplicate. Carrying
    /// forward would produce a 0.0% Monday delta that reads as "flat" rather
    /// than "closed".
    @Test("A day the market did not trade is skipped")
    func nonTradingDayIsSkipped() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)
            let listId = try #require(list.id)
            try await addStock(
                userId: userId, listId: listId,
                symbol: "AAPL", shares: 10, buyPrice: 150, on: app.db
            )
            // Priced on Friday only.
            try await addBar(symbol: "AAPL", day: Self.friday, close: 200, on: app.db)

            let job = PortfolioSnapshotJob()
            // Saturday: a price exists (Friday's close) but nothing traded today.
            let saturday = Self.friday.addingTimeInterval(86400)
            let outcome = try await job.capture(list: list, now: saturday, on: app.db)

            #expect(outcome == .marketClosed)
            #expect(try await snapshots(userId: userId, on: app.db).isEmpty)
        }
    }

    /// A dormant account must not accrue a row a day forever.
    @Test("An empty portfolio is not captured")
    func emptyPortfolioIsNotCaptured() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let list = try await makeList(userId: userId, on: app.db)

            let job = PortfolioSnapshotJob()
            let outcome = try await job.capture(list: list, now: Self.friday, on: app.db)

            #expect(outcome == .empty)
            #expect(try await snapshots(userId: userId, on: app.db).isEmpty)
        }
    }

    /// Model portfolios are hypotheticals; a value history for them would be a
    /// history of something that never happened.
    @Test("Only actual-mode portfolios are captured by a run")
    func modelPortfoliosAreSkippedByRun() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let model = try await makeList(userId: userId, mode: "model", on: app.db)
            let modelId = try #require(model.id)
            try await addStock(
                userId: userId, listId: modelId,
                symbol: "AAPL", shares: 10, buyPrice: 150, on: app.db
            )
            try await addBar(symbol: "AAPL", day: Self.friday, close: 200, on: app.db)

            let job = PortfolioSnapshotJob()
            await job.runOnceAsLeader(app)

            #expect(try await snapshots(userId: userId, on: app.db).isEmpty)
        }
    }

    // MARK: - Multiple portfolios

    @Test("Each portfolio list gets its own row for the day")
    func perPortfolioRows() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let first = try await makeList(userId: userId, name: "First", on: app.db)
            let second = try await makeList(userId: userId, name: "Second", on: app.db)
            try await addStock(
                userId: userId, listId: #require(first.id),
                symbol: "AAPL", shares: 10, buyPrice: 150, on: app.db
            )
            try await addStock(
                userId: userId, listId: #require(second.id),
                symbol: "MSFT", shares: 5, buyPrice: 300, on: app.db
            )
            try await addBar(symbol: "AAPL", day: Self.friday, close: 200, on: app.db)
            try await addBar(symbol: "MSFT", day: Self.friday, close: 400, on: app.db)

            let job = PortfolioSnapshotJob()
            #expect(try await job.capture(list: first, now: Self.friday, on: app.db) == .captured)
            #expect(try await job.capture(list: second, now: Self.friday, on: app.db) == .captured)

            let rows = try await snapshots(userId: userId, on: app.db)
            #expect(rows.count == 2)
            #expect(Set(rows.map(\.marketValue)) == [2000, 2000])
        }
    }
}
