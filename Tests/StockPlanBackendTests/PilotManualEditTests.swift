import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Manual edits against a pilot-followed portfolio. These live in the
/// PilotController suite so they share its serialization: they flip
/// PILOTS_ENABLED, which is process-wide.
extension PilotControllerTests {
    private struct Followed {
        let follow: PilotFollow
        let listId: UUID
        let stockId: UUID
        let account: Account
        let instrumentId: UUID
    }

    /// A hypothetical portfolio followed into a pilot: the pilot account holds
    /// 500 of simulated cash and the portfolio 5 AAPL.
    private func seedFollowedPortfolio(userId: UUID, on db: any Database) async throws -> Followed {
        let pilot = Pilot(kind: .politician, slug: "p-\(UUID().uuidString.prefix(6).lowercased())", displayName: "Test Pilot", chamber: "house", nameAliases: ["Test Pilot"])
        try await pilot.create(on: db)
        let list = PortfolioList(userId: userId, name: "Pilot copy \(UUID().uuidString.prefix(4))", mode: "hypothetical")
        try await list.create(on: db)
        let listId = try list.requireID()
        let account = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: db)
        try await CashBalance(accountId: account.requireID(), currency: "USD", balance: 500, asOf: Date()).create(on: db)
        let stock = Stock(userId: userId, portfolioListId: listId, symbol: "AAPL", shares: 5, buyPrice: 100, buyDate: Date(), sourceProvider: "pilot")
        try await stock.create(on: db)
        let follow = try PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: 1000)
        try await follow.create(on: db)
        // Resolved locally so neither the sell nor a recorded trade reaches market search.
        let instrument: Instrument
        if let existing = try await Instrument.query(on: db).filter(\.$symbol == "AAPL").first() {
            instrument = existing
        } else {
            instrument = Instrument(conid: "test:AAPL:\(UUID().uuidString.prefix(6))", symbol: "AAPL", exchange: "TEST", currency: "USD")
            try await instrument.create(on: db)
        }
        return try Followed(follow: follow, listId: listId, stockId: stock.requireID(), account: account, instrumentId: instrument.requireID())
    }

    private func cash(_ accountId: UUID, on db: any Database) async throws -> Double {
        try await CashBalance.query(on: db).filter(\.$accountId == accountId).all().reduce(0) { $0 + $1.balance }
    }

    private func expectConflict(_ app: Application, _ method: HTTPMethod, _ path: String, token: String, _ label: String, body: ((inout TestingHTTPRequest) throws -> Void)? = nil) async throws {
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try body?(&req)
        }) { res async throws in
            #expect(res.status == .conflict, "\(label): \(res.status) \(res.body.string)")
            #expect(res.body.string.contains("managed by a pilot follow"), "\(label)")
        }
    }

    @Test("manual sells, adds, edits, deletes and recorded trades on a followed portfolio are 409 and change nothing")
    func manualEditsAreRefused() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let seeded = try await seedFollowedPortfolio(userId: userId, on: app.db)
            let accountId = try seeded.account.requireID()
            let listId = seeded.listId.uuidString
            let other = PortfolioList(userId: userId, name: "Elsewhere", mode: "hypothetical")
            try await other.create(on: app.db)
            let elsewhere = try Stock(userId: userId, portfolioListId: other.requireID(), symbol: "KO", shares: 2, buyPrice: 60, buyDate: Date())
            try await elsewhere.create(on: app.db)
            // A hand-entered row on the followed portfolio's account (recorded before it was followed).
            let manualRow = Transaction(accountId: accountId, instrumentId: seeded.instrumentId, externalId: "manual:\(UUID().uuidString.lowercased())", type: "buy", quantity: 1, price: 100, currency: "USD", tradeDate: Date())
            try await manualRow.create(on: app.db)

            try await expectConflict(app, .POST, "v1/stocks/id/\(seeded.stockId)/sell", token: token, "sell") { req in
                try req.content.encode(SellStockRequest(sharesToSell: 1, sellPrice: 150, sellDate: "2026-04-10"))
            }
            try await expectConflict(app, .POST, "v1/stocks", token: token, "add") { req in
                try req.content.encode(StockRequest(symbol: "MSFT", shares: 1, buyPrice: 10, buyDate: "2026-01-02", notes: nil, portfolioListId: listId))
            }
            try await expectConflict(app, .POST, "v1/stocks/bulk", token: token, "bulk add") { req in
                try req.content.encode(BulkStockRequest(stocks: [StockRequest(symbol: "MSFT", shares: 1, buyPrice: 10, buyDate: "2026-01-02", notes: nil, portfolioListId: listId)]))
            }
            try await expectConflict(app, .PUT, "v1/stocks/id/\(seeded.stockId)", token: token, "edit") { req in
                try req.content.encode(StockRequest(symbol: "AAPL", shares: 50, buyPrice: 1, buyDate: "2026-01-02", notes: nil, portfolioListId: listId))
            }
            try await expectConflict(app, .PUT, "v1/stocks/id/\(elsewhere.requireID())", token: token, "move in") { req in
                try req.content.encode(StockRequest(symbol: "KO", shares: 2, buyPrice: 60, buyDate: "2026-01-02", notes: nil, portfolioListId: listId))
            }
            try await expectConflict(app, .DELETE, "v1/stocks/id/\(seeded.stockId)", token: token, "delete")
            try await expectConflict(app, .PATCH, "v1/transactions/\(manualRow.requireID())", token: token, "edit trade") { req in
                try req.content.encode(UpdateTransactionRequest(quantity: 9, price: nil, currency: nil, tradeDate: nil, settleDate: nil, fees: nil))
            }
            try await expectConflict(app, .DELETE, "v1/transactions/\(manualRow.requireID())", token: token, "delete trade")
            try await expectConflict(app, .POST, "v1/transactions", token: token, "record trade") { req in
                try req.content.encode(CreateTransactionRequest(symbol: "AAPL", type: "buy", quantity: 1, price: 100, currency: nil, tradeDate: "2026-01-02", settleDate: nil, fees: nil, portfolioListId: listId))
            }

            let stocks = try await Stock.query(on: app.db).filter(\.$portfolioListId == seeded.listId).all()
            #expect(stocks.map(\.symbol) == ["AAPL"])
            #expect(stocks.first?.shares == 5)
            #expect(try await Stock.find(elsewhere.requireID(), on: app.db)?.portfolioListId == other.id)
            #expect(try await cash(accountId, on: app.db) == 500)
            let accountIds = try await Account.query(on: app.db).filter(\.$userId == userId).all().map { try $0.requireID() }
            #expect(accountIds == [accountId])
            let rows = try await Transaction.query(on: app.db).filter(\.$accountId ~~ accountIds).all()
            #expect(rows.map(\.id) == [manualRow.id])
            #expect(rows.first?.quantity == 1)
        }
    }

    @Test("after unfollowing, a manual sell and a recorded trade use the pilot account; the legacy manual account is untouched", .databaseLocked)
    func unfollowedPortfolioKeepsPilotAccount() async throws {
        setenv("PILOTS_ENABLED", "true", 1)
        defer { unsetenv("PILOTS_ENABLED") }
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let seeded = try await seedFollowedPortfolio(userId: userId, on: app.db)
            let pilotAccountId = try seeded.account.requireID()
            let legacy = Account(userId: userId, externalId: "manual-\(userId.uuidString.lowercased())", broker: "manual", displayName: "Manual", baseCurrency: "USD")
            try await legacy.create(on: app.db)
            let legacyId = try legacy.requireID()
            try await CashBalance(accountId: legacyId, currency: "USD", balance: 777, asOf: Date()).create(on: app.db)

            try await app.testing().test(.DELETE, "v1/pilot-follows/\(seeded.follow.requireID())", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res async throws in
                #expect(res.status == .noContent)
            }
            #expect(try await PilotFollow.find(seeded.follow.requireID(), on: app.db) == nil)

            try await app.testing().test(.POST, "v1/stocks/id/\(seeded.stockId)/sell", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(SellStockRequest(sharesToSell: 1, sellPrice: 150, sellDate: "2026-04-10"))
            }) { res async throws in
                #expect(res.status == .ok, "\(res.body.string)")
                #expect(try res.content.decode(StockResponse.self).shares == 4)
            }
            #expect(try await cash(pilotAccountId, on: app.db) == 650)

            var recorded: TransactionResponse?
            try await app.testing().test(.POST, "v1/transactions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(CreateTransactionRequest(symbol: "AAPL", type: "buy", quantity: 1, price: 100, currency: nil, tradeDate: "2026-04-11", settleDate: nil, fees: nil, portfolioListId: seeded.listId.uuidString))
            }) { res async throws in
                #expect(res.status == .created, "\(res.body.string)")
                recorded = try res.content.decode(TransactionResponse.self)
            }
            #expect(recorded?.accountId == pilotAccountId.uuidString)

            let legacyAfter = try #require(try await Account.find(legacyId, on: app.db))
            #expect(legacyAfter.portfolioId == nil)
            #expect(try await cash(legacyId, on: app.db) == 777)
            #expect(try await Transaction.query(on: app.db).filter(\.$accountId == legacyId).count() == 0)
            let bound = try await Account.query(on: app.db).filter(\.$portfolioId == seeded.listId).all()
            #expect(bound.map(\.broker) == [PilotAccountResolver.broker])
        }
    }
}
