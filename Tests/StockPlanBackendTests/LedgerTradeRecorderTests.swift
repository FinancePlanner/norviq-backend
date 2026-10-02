import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("LedgerTradeRecorder", .serialized)
struct LedgerTradeRecorderTests {
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

    private func makeInstrument(_ symbol: String, on db: any Database) async throws -> UUID {
        let instrument = Instrument(conid: "test:\(symbol):\(UUID().uuidString.prefix(6))", symbol: symbol, exchange: "TEST", currency: "USD")
        try await instrument.create(on: db)
        return try instrument.requireID()
    }

    private func cash(userId: UUID, listId: UUID, on db: any Database) async throws -> Double {
        let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: db)
        return try await CashBalance.query(on: db).filter(\.$accountId == account.requireID()).all().reduce(0) { $0 + $1.balance }
    }

    @Test("sell endpoint: partial sale writes a manual transaction and credits cash; full sale deletes the row")
    func sellCharacterization() async throws {
        try await withApp { app in
            // Register through the API so the sell runs through the real controller.
            let suffix = UUID().uuidString.prefix(8).lowercased()
            var auth: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(StockPlanBackend.AuthRegisterRequest(username: "ledger_\(suffix)", password: "Password123!", confirmPassword: "Password123!", email: "ledger+\(suffix)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)))
            }, afterResponse: { res async throws in auth = try res.content.decode(AuthResponse.self) })
            let token = try #require(auth).token
            let userId = try #require(auth).userId

            var stock: StockResponse?
            try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(StockRequest(symbol: "AAPL", shares: 5, buyPrice: 100, buyDate: "2026-01-02", notes: nil))
            }, afterResponse: { res async throws in stock = try res.content.decode(StockResponse.self) })
            let created = try #require(stock)

            try await app.testing().test(.POST, "v1/stocks/id/\(created.id)/sell", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(SellStockRequest(sharesToSell: 2, sellPrice: 150, sellDate: "2026-04-10"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(StockResponse.self).shares == 3)
            })
            let row = try #require(try await Stock.query(on: app.db).filter(\.$userId == userId).first())
            #expect(try await cash(userId: userId, listId: row.portfolioListId, on: app.db) == 300)
            let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: row.portfolioListId, on: app.db)
            let sells = try await Transaction.query(on: app.db).filter(\.$accountId == account.requireID()).all()
            func utcDay(_ iso: String) -> Date {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
                let p = iso.split(separator: "-").compactMap { Int($0) }
                return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
            }
            #expect(sells.count == 1)
            let first = try #require(sells.first)
            #expect(first.externalId?.hasPrefix("manual:") == true)
            #expect(first.type == "sell")
            #expect(first.quantity == 2)
            #expect(first.price == 150)
            #expect(first.currency == account.baseCurrency)
            #expect(first.tradeDate == utcDay("2026-04-10"))

            try await app.testing().test(.POST, "v1/stocks/id/\(created.id)/sell", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(SellStockRequest(sharesToSell: 3, sellPrice: 100, sellDate: "2026-04-11"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(StockResponse.self).shares == 0)
            })
            #expect(try await Stock.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(try await cash(userId: userId, listId: row.portfolioListId, on: app.db) == 600)
            let all = try await Transaction.query(on: app.db).filter(\.$accountId == account.requireID()).sort(\.$tradeDate, .ascending).all()
            #expect(all.count == 2)
            let last = try #require(all.last)
            #expect(last.quantity == 3)
            #expect(last.price == 100)
            #expect(last.tradeDate == utcDay("2026-04-11"))
        }
    }

    private func makeHypothetical(userId: UUID, on db: any Database) async throws -> UUID {
        let list = PortfolioList(userId: userId, name: "Sim \(UUID().uuidString.prefix(6))", mode: "hypothetical")
        try await list.create(on: db)
        return try list.requireID()
    }

    @Test("buy creates a row, merges weighted average on a second buy, debits cash, writes transactions")
    func buyMerges() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let aapl = try await makeInstrument("AAPL", on: app.db)
            let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: app.db)
            try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: 1000, asOf: Date()).create(on: app.db)

            let recorder = LedgerTradeRecorder()
            let day = Date(timeIntervalSince1970: 1_790_812_800)
            _ = try await app.db.transaction { db in
                try await recorder.record([
                    LedgerTrade(symbol: "AAPL", side: .buy, quantity: 2, price: 100, tradeDate: day, instrumentId: aapl, externalId: "pilot:f:v1:AAPL", stockId: nil),
                ], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db)
            }
            let results = try await app.db.transaction { db in
                try await recorder.record([
                    LedgerTrade(symbol: "AAPL", side: .buy, quantity: 2, price: 200, tradeDate: day, instrumentId: aapl, externalId: "pilot:f:v2:AAPL", stockId: nil),
                ], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db)
            }
            #expect(results == [LedgerTradeResult(symbol: "AAPL", remainingShares: 4)])
            let rows = try await Stock.query(on: app.db).filter(\.$portfolioListId == listId).all()
            #expect(rows.count == 1)
            #expect(rows.first?.buyPrice == 150)
            #expect(rows.first?.sourceProvider == "pilot")
            #expect(try await cash(userId: userId, listId: listId, on: app.db) == 400)
            #expect(try await Transaction.query(on: app.db).filter(\.$accountId == account.requireID()).count() == 2)
        }
    }

    @Test("buy beyond available cash throws and writes nothing")
    func insufficientCash() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let recorder = LedgerTradeRecorder()
            await #expect(throws: LedgerTradeRecorderError.insufficientCash("AAPL")) {
                try await app.db.transaction { db in
                    try await recorder.record([
                        LedgerTrade(symbol: "AAPL", side: .buy, quantity: 1, price: 10, tradeDate: Date(), instrumentId: nil, externalId: "x", stockId: nil),
                    ], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db)
                }
            }
            #expect(try await Stock.query(on: app.db).filter(\.$portfolioListId == listId).count() == 0)
        }
    }

    @Test("the same external id twice is rejected by the database")
    func duplicateExternalId() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let aapl = try await makeInstrument("AAPL", on: app.db)
            let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: app.db)
            try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: 1000, asOf: Date()).create(on: app.db)
            let trade = LedgerTrade(symbol: "AAPL", side: .buy, quantity: 1, price: 10, tradeDate: Date(), instrumentId: aapl, externalId: "pilot:f:v1:AAPL", stockId: nil)
            let recorder = LedgerTradeRecorder()
            _ = try await app.db.transaction { db in try await recorder.record([trade], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db) }
            await #expect(throws: (any Error).self) {
                try await app.db.transaction { db in try await recorder.record([trade], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db) }
            }
            #expect(try await cash(userId: userId, listId: listId, on: app.db) == 990)
        }
    }
}
