import Fluent
import Foundation
import SQLKit
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("PilotMirrorService", .serialized)
struct PilotMirrorServiceTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
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

    private func makeUser(on db: any Database) async throws -> UUID {
        let id = UUID()
        try await User(id: id, email: "ledger_\(id.uuidString.prefix(8).lowercased())@example.com", passwordHash: "x").create(on: db)
        return id
    }

    private func makeHypothetical(userId: UUID, on db: any Database) async throws -> UUID {
        let list = PortfolioList(userId: userId, name: "Sim \(UUID().uuidString.prefix(6))", mode: "hypothetical")
        try await list.create(on: db)
        return try list.requireID()
    }

    private let now = Date(timeIntervalSince1970: 1_790_812_800)

    private func makePilot(on db: any Database) async throws -> Pilot {
        let pilot = Pilot(kind: .politician, slug: "p-\(UUID().uuidString.prefix(6))", displayName: "Test Pilot", chamber: "house", nameAliases: ["Test Pilot"])
        try await pilot.create(on: db)
        return pilot
    }

    private func version(_ pilot: Pilot, _ v: Int, _ weights: [String: Double], on db: any Database) async throws -> PilotBookVersion {
        let row = try PilotBookVersion(pilotId: pilot.requireID(), version: v, computedAt: now, weights: weights, skippedPuts: 0)
        try await row.create(on: db)
        return row
    }

    private func service(prices: [String: Double], limit: PilotWatchlistLimit? = nil) -> PilotMirrorService {
        PilotMirrorService(
            quote: { symbol in
                guard let price = prices[symbol] else { throw Abort(.badGateway) }
                return price
            },
            instrument: { _ in nil },
            watchlistLimit: limit ?? { _, _, _ in }
        )
    }

    private func portfolioFollow(userId: UUID, pilot: Pilot, cash: Double, on db: any Database) async throws -> PilotFollow {
        let listId = try await makeHypothetical(userId: userId, on: db)
        let account = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: db)
        try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: cash, asOf: now).create(on: db)
        let follow = try PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: cash)
        try await follow.create(on: db)
        return follow
    }

    @Test("portfolio follow buys the book and records events and applied_version")
    func appliesBook() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 10000, on: app.db)
            let v1 = try await version(pilot, 1, ["AAPL": 0.5, "MSFT": 0.5], on: app.db)
            let applied = try await service(prices: ["AAPL": 100, "MSFT": 250]).apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            #expect(applied)
            let stocks = try await Stock.query(on: app.db).filter(\.$portfolioListId == follow.portfolioListId!).sort(\.$symbol).all()
            #expect(stocks.map(\.symbol) == ["AAPL", "MSFT"])
            #expect(stocks.map(\.shares) == [50, 20])
            let events = try await PilotFollowEvent.query(on: app.db).filter(\.$followId == follow.requireID()).all()
            #expect(Set(events.map(\.kind)) == ["buy"])
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 1)
        }
    }

    @Test("with real instruments, stocks equal the pilot account's net transactions; a stale re-apply adds none")
    func stocksAndTransactionsAgree() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 10000, on: app.db)
            let followId = try follow.requireID()
            let listId = try #require(follow.portfolioListId)
            var instruments: [String: UUID] = [:]
            for symbol in ["AAPL", "MSFT"] {
                let instrument = Instrument(conid: "test:\(symbol):\(UUID().uuidString.prefix(6))", symbol: symbol, exchange: "TEST", currency: "USD")
                try await instrument.create(on: app.db)
                instruments[symbol] = try instrument.requireID()
            }
            let ids = instruments
            let svc = PilotMirrorService(
                quote: { symbol in ["AAPL": 100, "MSFT": 250][symbol] ?? 0 },
                instrument: { symbol in ids[symbol] },
                watchlistLimit: { _, _, _ in }
            )
            let account = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: app.db)
            let accountId = try account.requireID()
            let symbolById = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })

            func assertLedgerAgrees() async throws {
                let stocks = try await Stock.query(on: app.db).filter(\.$portfolioListId == listId).all()
                let held = stocks.reduce(into: [String: Double]()) { $0[$1.symbol, default: 0] += $1.shares }
                let txs = try await Transaction.query(on: app.db).filter(\.$accountId == accountId).all()
                var net: [String: Double] = [:]
                for tx in txs {
                    let symbol = try #require(symbolById[tx.instrumentId])
                    let qty = tx.quantity ?? 0
                    net[symbol, default: 0] += tx.type == "buy" ? qty : -qty
                }
                for symbol in Set(held.keys).union(net.keys) {
                    #expect(abs((held[symbol] ?? 0) - (net[symbol] ?? 0)) < 1e-9, "\(symbol): stocks \(held[symbol] ?? 0) vs transactions \(net[symbol] ?? 0)")
                }
            }

            let v1 = try await version(pilot, 1, ["AAPL": 0.5, "MSFT": 0.5], on: app.db)
            #expect(try await svc.apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db))
            try await assertLedgerAgrees()
            let v1Txs = try await Transaction.query(on: app.db).filter(\.$accountId == accountId).all()
            #expect(v1Txs.count == 2)
            for tx in v1Txs {
                let symbol = try #require(symbolById[tx.instrumentId])
                #expect(tx.externalId == "pilot:\(followId.uuidString.lowercased()):v1:\(symbol)")
            }

            // The stale pod: same version again, follow as it was before the claim.
            #expect(try await svc.apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db) == false)
            #expect(try await Transaction.query(on: app.db).filter(\.$accountId == accountId).count() == 2)
            try await assertLedgerAgrees()

            // A rebalance that sells one name out and buys the other keeps them in step.
            let v2 = try await version(pilot, 2, ["AAPL": 1.0], on: app.db)
            let current = try #require(try await PilotFollow.find(followId, on: app.db))
            #expect(try await svc.apply(follow: current, pilot: pilot, version: v2, previous: v1, now: now, on: app.db))
            try await assertLedgerAgrees()
            #expect(try await Stock.query(on: app.db).filter(\.$portfolioListId == listId).filter(\.$symbol == "MSFT").count() == 0)
        }
    }

    @Test("applying the same version twice changes nothing the second time")
    func applyIsIdempotent() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 10000, on: app.db)
            let v1 = try await version(pilot, 1, ["AAPL": 1.0], on: app.db)
            let svc = service(prices: ["AAPL": 100])
            #expect(try await svc.apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db))
            let stale = try #require(try await PilotFollow.find(follow.requireID(), on: app.db))
            // This second call is the stale pod: claim reads the DB, so it must lose.
            #expect(try await svc.apply(follow: stale, pilot: pilot, version: v1, previous: nil, now: now, on: app.db) == false)
            let stock = try #require(try await Stock.query(on: app.db).filter(\.$portfolioListId == follow.portfolioListId!).first())
            #expect(stock.shares == 100)
        }
    }

    @Test("a small unpriced target is skipped with an event; priced symbols still trade")
    func unpricedSymbolLeftAlone() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 2000, on: app.db)
            let v1 = try await version(pilot, 1, ["AAPL": 0.95, "ZZZZ": 0.05], on: app.db)
            let applied = try await service(prices: ["AAPL": 100]).apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            #expect(applied)
            let events = try await PilotFollowEvent.query(on: app.db).filter(\.$followId == follow.requireID()).all()
            #expect(events.contains { $0.kind == "skipped_unpriced" && $0.symbol == "ZZZZ" })
            #expect(events.contains { $0.kind == "buy" && $0.symbol == "AAPL" })
            let stock = try #require(try await Stock.query(on: app.db).filter(\.$portfolioListId == follow.portfolioListId!).first())
            #expect(stock.shares == 19)
            let account = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: follow.portfolioListId!, on: app.db)
            let cash = try await CashBalance.query(on: app.db).filter(\.$accountId == account.requireID()).all().reduce(0.0) { $0 + $1.balance }
            #expect(abs(cash - 100) < 1e-6)
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 1)
        }
    }

    @Test("more than 10% of the book unpriced throws before claiming; nothing is written")
    func largelyUnpricedDoesNotConsumeVersion() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 1000, on: app.db)
            let v1 = try await version(pilot, 1, ["AAPL": 0.5, "ZZZZ": 0.5], on: app.db)
            await #expect(throws: PilotMirrorError.quotesUnavailable) {
                _ = try await service(prices: ["AAPL": 100]).apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            }
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 0)
            #expect(try await Stock.query(on: app.db).filter(\.$portfolioListId == follow.portfolioListId!).count() == 0)
            #expect(try await PilotFollowEvent.query(on: app.db).filter(\.$followId == follow.requireID()).count() == 0)
            let account = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: follow.portfolioListId!, on: app.db)
            #expect(try await Transaction.query(on: app.db).filter(\.$accountId == account.requireID()).count() == 0)
            let cash = try await CashBalance.query(on: app.db).filter(\.$accountId == account.requireID()).all().reduce(0.0) { $0 + $1.balance }
            #expect(cash == 1000)
        }
    }

    @Test("a total quote outage throws before claiming; a later run applies")
    func quoteOutageDoesNotConsumeVersion() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 10000, on: app.db)
            let v1 = try await version(pilot, 1, ["AAPL": 1.0], on: app.db)
            await #expect(throws: PilotMirrorError.quotesUnavailable) {
                _ = try await service(prices: [:]).apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            }
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 0)
            #expect(try await Stock.query(on: app.db).filter(\.$portfolioListId == follow.portfolioListId!).count() == 0)
            #expect(try await PilotFollowEvent.query(on: app.db).filter(\.$followId == follow.requireID()).count() == 0)
            let applied = try await service(prices: ["AAPL": 100]).apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            #expect(applied)
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 1)
        }
    }

    @Test("a position with sub-micro-share precision is sold out exactly")
    func sellsOutUnroundedHolding() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 0, on: app.db)
            try await Stock(userId: userId, portfolioListId: follow.portfolioListId!, symbol: "AAPL", shares: 1.0000006, buyPrice: 100, buyDate: now).create(on: app.db)
            let v1 = try await version(pilot, 1, ["MSFT": 1.0], on: app.db)
            let applied = try await service(prices: ["AAPL": 100, "MSFT": 100]).apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            #expect(applied)
            #expect(try await Stock.query(on: app.db).filter(\.$portfolioListId == follow.portfolioListId!).filter(\.$symbol == "AAPL").count() == 0)
        }
    }

    @Test("watchlist follow: added, exited, re-added")
    func watchlistFeed() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let list = WatchlistList(userId: userId, name: "Feed \(UUID().uuidString.prefix(4))")
            try await list.create(on: app.db)
            let follow = try PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .watchlist, watchlistListId: list.requireID())
            try await follow.create(on: app.db)
            try await PilotDisclosureRecord(pilotId: pilot.requireID(), sourceKey: "a", symbol: "NVDA", side: .buy, instrument: .stock, transactionDate: "2026-09-14").create(on: app.db)

            let svc = service(prices: [:])
            let v1 = try await version(pilot, 1, ["NVDA": 1.0], on: app.db)
            _ = try await svc.apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            var item = try #require(try await WatchlistItem.query(on: app.db).filter(\.$watchlistListId == list.requireID()).first())
            #expect(item.status == WatchlistStatus.active.rawValue)
            #expect(item.note == "Test Pilot bought 2026-09-14")
            // The user annotates the mirrored item; later pilot activity must not erase it.
            item.note = "My thesis: AI capex"
            try await item.save(on: app.db)

            let v2 = try await version(pilot, 2, ["AAPL": 1.0], on: app.db)
            let reloaded = try #require(try await PilotFollow.find(follow.requireID(), on: app.db))
            _ = try await svc.apply(follow: reloaded, pilot: pilot, version: v2, previous: v1, now: now, on: app.db)
            item = try #require(try await WatchlistItem.find(item.requireID(), on: app.db))
            #expect(item.status == WatchlistStatus.exited.rawValue)

            let v3 = try await version(pilot, 3, ["NVDA": 1.0], on: app.db)
            let again = try #require(try await PilotFollow.find(follow.requireID(), on: app.db))
            _ = try await svc.apply(follow: again, pilot: pilot, version: v3, previous: v2, now: now, on: app.db)
            item = try #require(try await WatchlistItem.find(item.requireID(), on: app.db))
            #expect(item.status == WatchlistStatus.active.rawValue)
            let note = try #require(item.note)
            #expect(note.hasPrefix("My thesis: AI capex · "))
            #expect(note.hasSuffix(" · Test Pilot bought 2026-09-14"))
        }
    }

    @Test("watchlist follow stops at the item limit, highest weight first")
    func watchlistRespectsItemLimit() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let list = WatchlistList(userId: userId, name: "Feed \(UUID().uuidString.prefix(4))")
            try await list.create(on: app.db)
            let follow = try PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .watchlist, watchlistListId: list.requireID())
            try await follow.create(on: app.db)
            let limited = service(prices: [:]) { _, current, _ in
                if current >= 2 {
                    throw BillingUpgradeRequiredError(feature: .watchlistItems, plan: "free", limit: 2, current: current)
                }
            }
            let v1 = try await version(pilot, 1, ["A": 0.5, "B": 0.3, "C": 0.2], on: app.db)
            _ = try await limited.apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            let symbols = try await WatchlistItem.query(on: app.db).filter(\.$watchlistListId == list.requireID()).all().map(\.symbol).sorted()
            #expect(symbols == ["A", "B"])
            let events = try await PilotFollowEvent.query(on: app.db).filter(\.$followId == follow.requireID()).all()
            #expect(events.contains { $0.kind == "skipped_limit" && $0.symbol == "C" })
        }
    }
}
