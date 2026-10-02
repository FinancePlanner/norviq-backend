import Fluent
import Foundation
import NIOCore
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// G1: writers other than StockService/TransactionService must not reach a
/// followed portfolio.
extension StagingGatesTests {
    private func expectManaged(_ res: TestingHTTPResponse, _ label: String) {
        #expect(res.status == .conflict, "\(label): \(res.status) \(res.body.string)")
        #expect(res.body.string.contains("managed by a pilot follow"), "\(label): \(res.body.string)")
    }

    @Test("CSV import into a followed portfolio is 409 before any write")
    func csvImportIntoFollowedListIsRefused() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await grantPro(userId, on: app)
            _ = try await seedInstrument(symbol: "AMD", on: app.db)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            let before = try await stockSnapshot(listId: seeded.listId, on: app.db)
            let csv = """
            symbol,shares,buy_price,buy_date
            AMD,9,120.25,2026-02-03
            """
            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr&portfolioListId=\(seeded.listId)&confirmMergeExisting=true", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }) { res async throws in
                expectManaged(res, "csv commit")
            }
            #expect(try await stockSnapshot(listId: seeded.listId, on: app.db) == before)
            #expect(try await Stock.query(on: app.db).filter(\.$userId == userId).filter(\.$symbol == "AMD").count() == 0)
            #expect(try await Account.query(on: app.db).filter(\.$userId == userId).filter(\.$broker == "ibkr").count() == 0)
            #expect(try await BrokerConnection.query(on: app.db).filter(\.$userId == userId).count() == 0)
        }
    }

    @Test("CSV import into an unfollowed portfolio still writes")
    func csvImportIntoUnfollowedListStillWrites() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await grantPro(userId, on: app)
            _ = try await seedInstrument(symbol: "AMD", on: app.db)
            _ = try await seedFollowedList(userId: userId, on: app.db)
            let plain = PortfolioList(userId: userId, name: "Plain", mode: "actual")
            try await plain.create(on: app.db)
            let csv = """
            symbol,shares,buy_price,buy_date
            AMD,9,120.25,2026-02-03
            """
            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr&portfolioListId=\(plain.requireID())", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }) { res async throws in
                #expect(res.status == .ok, "\(res.status) \(res.body.string)")
            }
            #expect(try await stockSnapshot(listId: plain.requireID(), on: app.db) == ["AMD:9.0:ibkr"])
        }
    }

    @Test("cash positions on a followed portfolio are 409 and unchanged; an unfollowed one still works")
    func cashPositionsOnFollowedListAreRefused() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await grantPro(userId, on: app)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            let existing = PortfolioCashPositionRecord(portfolioId: seeded.listId, label: "Old", currency: "USD", balance: 10, asOf: Date())
            try await existing.create(on: app.db)
            let cashId = try existing.requireID()
            let body = PortfolioCashPositionRequest(label: "Hand cash", currency: "USD", balance: 5000, asOf: "2026-09-01")

            try await app.testing().test(.POST, "v1/portfolios/\(seeded.listId)/cash", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(body)
            }) { res async throws in expectManaged(res, "create cash") }
            try await app.testing().test(.PUT, "v1/portfolios/\(seeded.listId)/cash/\(cashId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(body)
            }) { res async throws in expectManaged(res, "update cash") }
            try await app.testing().test(.DELETE, "v1/portfolios/\(seeded.listId)/cash/\(cashId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }) { res async throws in expectManaged(res, "delete cash") }

            let rows = try await PortfolioCashPositionRecord.query(on: app.db).filter(\.$portfolioId == seeded.listId).all()
            #expect(rows.count == 1)
            #expect(rows.first?.balance == 10)
            #expect(rows.first?.label == "Old")

            let plain = PortfolioList(userId: userId, name: "Plain", mode: "hypothetical")
            try await plain.create(on: app.db)
            var created: PortfolioCashPosition?
            try await app.testing().test(.POST, "v1/portfolios/\(plain.requireID())/cash", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(body)
            }) { res async throws in
                #expect(res.status == .created, "\(res.body.string)")
                created = try res.content.decode(PortfolioCashPosition.self)
            }
            let id = try #require(created?.id)
            try await app.testing().test(.PUT, "v1/portfolios/\(plain.requireID())/cash/\(id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(PortfolioCashPositionRequest(label: "Hand cash", currency: "USD", balance: 42, asOf: "2026-09-02"))
            }) { res async throws in #expect(res.status == .ok, "\(res.body.string)") }
            try await app.testing().test(.DELETE, "v1/portfolios/\(plain.requireID())/cash/\(id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }) { res async throws in #expect(res.status == .noContent) }
        }
    }

    @Test("deleting a followed list through the legacy route is 409: its simulated rows never merge into the default")
    func legacyListDeleteOfFollowedListIsRefused() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let main = PortfolioList(userId: userId, name: "Main", isDefault: true)
            try await main.create(on: app.db)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            try await app.testing().test(.DELETE, "v1/portfolio/lists/\(seeded.listId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }) { res async throws in expectManaged(res, "legacy delete") }
            #expect(try await PortfolioList.find(seeded.listId, on: app.db) != nil)
            #expect(try await stockSnapshot(listId: seeded.listId, on: app.db) == ["AAPL:5.0:pilot"])
            #expect(try await stockSnapshot(listId: main.requireID(), on: app.db).isEmpty)

            // Unfollowed lists still delete and merge into the default.
            let plain = PortfolioList(userId: userId, name: "Plain")
            try await plain.create(on: app.db)
            try await Stock(userId: userId, portfolioListId: plain.requireID(), symbol: "KO", shares: 2, buyPrice: 60, buyDate: Date()).create(on: app.db)
            try await app.testing().test(.DELETE, "v1/portfolio/lists/\(plain.requireID())", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }) { res async throws in #expect(res.status == .noContent, "\(res.body.string)") }
            #expect(try await stockSnapshot(listId: main.requireID(), on: app.db) == ["KO:2.0:-"])
        }
    }

    @Test("binding an IBKR connection to a followed portfolio is 409 and stores nothing", .databaseLocked)
    func ibkrConnectToFollowedListIsRefused() async throws {
        // The start route checks its redirect allowlist before the target list.
        // `.databaseLocked` holds the exclusive lock, so no other app is reading it.
        let redirect = "norviqa://oauth/callback"
        let previous = ProcessInfo.processInfo.environment["OAUTH_ALLOWED_REDIRECT_URIS"]
        setenv("OAUTH_ALLOWED_REDIRECT_URIS", redirect, 1)
        defer {
            if let previous {
                setenv("OAUTH_ALLOWED_REDIRECT_URIS", previous, 1)
            } else {
                unsetenv("OAUTH_ALLOWED_REDIRECT_URIS")
            }
        }
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            try await app.testing().test(.POST, "v1/brokers/ibkr/connect/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BrokerConnectCredentialsRequest(token: "tok", queryId: "q1", portfolioListId: seeded.listId.uuidString), using: JSONEncoder())
            }) { res async throws in expectManaged(res, "connect credentials") }
            try await app.testing().test(.POST, "v1/brokers/ibkr/connect/start", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BrokerConnectStartRequest(redirectURI: redirect, portfolioListId: seeded.listId.uuidString))
            }) { res async throws in expectManaged(res, "connect start") }
            #expect(try await BrokerConnection.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(try await BrokerOAuthFlow.query(on: app.db).filter(\.$userId == userId).count() == 0)

            let plain = PortfolioList(userId: userId, name: "Plain")
            try await plain.create(on: app.db)
            try await app.testing().test(.POST, "v1/brokers/ibkr/connect/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BrokerConnectCredentialsRequest(token: "tok", queryId: "q1", portfolioListId: plain.requireID().uuidString), using: JSONEncoder())
            }) { res async throws in #expect(res.status == .ok, "\(res.body.string)") }
            #expect(try await BrokerConnection.query(on: app.db).filter(\.$userId == userId).first()?.portfolioListId == plain.id)
        }
    }

    // MARK: - IBKR sync

    /// Serves a gateway with one account holding `positions` of `symbol`, and
    /// nothing else (no trades, no cash, no contract details).
    private struct StubIBKRGateway: Client {
        let eventLoop: any EventLoop
        let accountId: String
        let symbol: String

        func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
            let path = request.url.path
            let body: String
            let status: HTTPStatus
            if path.hasSuffix("/portfolio/accounts") {
                (status, body) = (.ok, #"[{"accountId":"\#(accountId)","displayName":"Gate IBKR"}]"#)
            } else if path.hasSuffix("/positions/0") {
                (status, body) = (.ok, #"[{"ticker":"\#(symbol)","position":3,"avgCost":50,"currency":"USD"}]"#)
            } else if path.hasSuffix("/pa/transactions") {
                (status, body) = (.ok, "[]")
            } else if path.hasSuffix("/ledger") {
                (status, body) = (.ok, "{}")
            } else {
                (status, body) = (.notFound, "{}")
            }
            var headers = HTTPHeaders()
            headers.contentType = .json
            return eventLoop.makeSucceededFuture(ClientResponse(status: status, headers: headers, body: ByteBuffer(string: body)))
        }

        func delegating(to eventLoop: any EventLoop) -> any Client {
            StubIBKRGateway(eventLoop: eventLoop, accountId: accountId, symbol: symbol)
        }
    }

    /// Account ids are unique per broker across users, so each sync gets its own.
    private func runIBKRSync(_ app: Application, connection: BrokerConnection, userId: UUID, symbol: String) async throws -> BrokerSyncResponse {
        let accountId = "UGATE\(UUID().uuidString.prefix(8))"
        app.clients.use { app in StubIBKRGateway(eventLoop: app.eventLoopGroup.next(), accountId: accountId, symbol: symbol) }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        return try await IBKRBrokerSyncService(gatewayClient: IBKRBrokerGatewayClient(baseURL: "http://ibkr.test/v1/api", defaultCurrency: "USD"))
            .sync(connection: connection, userId: userId, on: req)
    }

    @Test("IBKR sync bound to a followed portfolio skips holdings without throwing")
    func ibkrSyncBoundToFollowedListSkipsHoldings() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let symbol = "GTA\(UUID().uuidString.prefix(4))".uppercased()
            _ = try await seedInstrument(symbol: symbol, on: app.db)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            let connection = BrokerConnection(userId: userId, provider: "ibkr", status: "connected", portfolioListId: seeded.listId)
            try await connection.create(on: app.db)

            let result = try await runIBKRSync(app, connection: connection, userId: userId, symbol: symbol)

            #expect(result.inserted == 0)
            #expect(try await stockSnapshot(listId: seeded.listId, on: app.db) == ["AAPL:5.0:pilot"])
            #expect(try await Stock.query(on: app.db).filter(\.$userId == userId).filter(\.$symbol == symbol).count() == 0)
            #expect(try await PortfolioList.find(seeded.listId, on: app.db)?.isDefault == false)
        }
    }

    @Test("IBKR sync bound to a followed portfolio still refreshes the account's lots and positions and says why holdings are missing")
    func ibkrSyncBoundToFollowedListKeepsLedgerCurrent() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let symbol = "GTD\(UUID().uuidString.prefix(4))".uppercased()
            let instrument = try await seedInstrument(symbol: symbol, on: app.db)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            let connection = BrokerConnection(userId: userId, provider: "ibkr", status: "connected", portfolioListId: seeded.listId)
            try await connection.create(on: app.db)

            _ = try await runIBKRSync(app, connection: connection, userId: userId, symbol: symbol)

            let account = try #require(try await Account.query(on: app.db).filter(\.$userId == userId).filter(\.$broker == "ibkr").first())
            let instrumentId = try instrument.requireID()
            let position = try await Position.query(on: app.db).filter(\.$accountId == account.requireID()).filter(\.$instrumentId == instrumentId).first()
            #expect(position?.quantity == 3)
            let lots = try await Lot.query(on: app.db).filter(\.$accountId == account.requireID()).filter(\.$instrumentId == instrumentId).all()
            #expect(lots.reduce(0) { $0 + $1.remainingQuantity } >= 3)
            #expect(try await Stock.query(on: app.db).filter(\.$userId == userId).filter(\.$symbol == symbol).count() == 0)
            #expect(try await stockSnapshot(listId: seeded.listId, on: app.db) == ["AAPL:5.0:pilot"])
            let saved = try #require(try await BrokerConnection.find(connection.requireID(), on: app.db))
            #expect(saved.statusDetail == "Holdings aren't copied into a portfolio that follows a pilot.")
            #expect(saved.status == "connected")
            #expect(saved.portfolioListId == seeded.listId)
        }
    }

    @Test("IBKR sync with no bound list never picks a followed portfolio")
    func ibkrSyncUnboundAvoidsFollowedList() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let symbol = "GTB\(UUID().uuidString.prefix(4))".uppercased()
            _ = try await seedInstrument(symbol: symbol, on: app.db)
            // The user's only list is a pilot portfolio.
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            let connection = BrokerConnection(userId: userId, provider: "ibkr", status: "connected")
            try await connection.create(on: app.db)

            let result = try await runIBKRSync(app, connection: connection, userId: userId, symbol: symbol)

            #expect(result.inserted == 1)
            #expect(try await stockSnapshot(listId: seeded.listId, on: app.db) == ["AAPL:5.0:pilot"])
            let written = try await Stock.query(on: app.db).filter(\.$userId == userId).filter(\.$symbol == symbol).all()
            #expect(written.count == 1)
            let target = try #require(written.first?.portfolioListId)
            #expect(target != seeded.listId)
            let list = try #require(try await PortfolioList.find(target, on: app.db))
            #expect(list.mode == "actual")
            #expect(list.isDefault)
            #expect(try await PortfolioList.find(seeded.listId, on: app.db)?.isDefault == false)
            let ibkrAccount = try #require(try await Account.query(on: app.db).filter(\.$userId == userId).filter(\.$broker == "ibkr").first())
            #expect(ibkrAccount.portfolioId == target)
            #expect(try await BrokerConnection.find(connection.requireID(), on: app.db)?.portfolioListId == target)
        }
    }

    @Test("IBKR sync prefers the bound list, else the default, for unfollowed users")
    func ibkrSyncUnfollowedTargets() async throws {
        try await withApp { app in
            let symbol = "GTC\(UUID().uuidString.prefix(4))".uppercased()
            _ = try await seedInstrument(symbol: symbol, on: app.db)

            // No bound list: the default, even when an older list exists.
            let (_, first) = try await registerTestUser(app: app)
            let older = PortfolioList(userId: first, name: "Older")
            try await older.create(on: app.db)
            let main = PortfolioList(userId: first, name: "Main", isDefault: true)
            try await main.create(on: app.db)
            let unbound = BrokerConnection(userId: first, provider: "ibkr", status: "connected")
            try await unbound.create(on: app.db)
            _ = try await runIBKRSync(app, connection: unbound, userId: first, symbol: symbol)
            #expect(try await Stock.query(on: app.db).filter(\.$userId == first).filter(\.$symbol == symbol).all().map(\.portfolioListId) == [main.id])

            // A bound list wins over the default.
            let (_, second) = try await registerTestUser(app: app)
            let secondMain = PortfolioList(userId: second, name: "Main", isDefault: true)
            try await secondMain.create(on: app.db)
            let bound = PortfolioList(userId: second, name: "Bound")
            try await bound.create(on: app.db)
            let connection = try BrokerConnection(userId: second, provider: "ibkr", status: "connected", portfolioListId: bound.requireID())
            try await connection.create(on: app.db)
            _ = try await runIBKRSync(app, connection: connection, userId: second, symbol: symbol)
            #expect(try await Stock.query(on: app.db).filter(\.$userId == second).filter(\.$symbol == symbol).all().map(\.portfolioListId) == [bound.id])
        }
    }
}
