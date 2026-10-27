import Fluent
import Foundation
import NIOCore
@testable import StockPlanBackend
import Testing
import Vapor

/// A sync must leave the account's lots explained by its stored trades: one
/// lot per acquisition, disposals kept across syncs, and open quantity equal
/// to the broker position. Earlier syncs replaced every lot with a snapshot,
/// which cascaded away realized history.
@Suite("IBKR sync ledger", .serialized)
struct IBKRSyncLedgerTests {
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
        try await User(id: id, email: "ibkr_ledger_\(id.uuidString.prefix(8).lowercased())@example.com", passwordHash: "x").create(on: db)
        return id
    }

    private func makeInstrument(_ symbol: String, on db: any Database) async throws -> UUID {
        let instrument = Instrument(conid: "test:\(symbol):\(UUID().uuidString.prefix(6))", symbol: symbol, exchange: "TEST", currency: "USD")
        try await instrument.create(on: db)
        return try instrument.requireID()
    }

    // MARK: - Gateway stub

    struct StubPosition {
        var ticker: String
        var quantity: Double
        var avgCost: Double
        var assetClass: String?
    }

    struct StubTrade {
        var id: String
        var symbol: String
        var type: String
        var quantity: Double
        var price: Double
        var daysAgo: Int
        var assetClass: String?
    }

    /// What the gateway reports. Shared by reference so a test can change it
    /// between syncs, the way the broker's state moves on.
    final class StubState: @unchecked Sendable {
        let accountId = "ULEDGER\(UUID().uuidString.prefix(8))"
        private let lock = NSLock()
        private var _positions: [StubPosition] = []
        private var _trades: [StubTrade] = []

        var positions: [StubPosition] {
            get { lock.withLock { _positions } }
            set { lock.withLock { _positions = newValue } }
        }

        var trades: [StubTrade] {
            get { lock.withLock { _trades } }
            set { lock.withLock { _trades = newValue } }
        }
    }

    /// Answers like the IBKR gateway: transactions only inside the requested
    /// `from`...`to` window, which is what makes later syncs see few trades.
    private struct StubIBKRGateway: Client {
        let eventLoop: any EventLoop
        let state: StubState

        func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
            let path = request.url.path
            let body: String
            let status: HTTPStatus
            if path.hasSuffix("/portfolio/accounts") {
                (status, body) = (.ok, #"[{"accountId":"\#(state.accountId)","displayName":"Ledger IBKR"}]"#)
            } else if path.hasSuffix("/positions/0") {
                (status, body) = (.ok, Self.json(state.positions.map(Self.positionJSON)))
            } else if path.hasSuffix("/pa/transactions") {
                let window = Self.window(of: request.url)
                let inWindow = state.trades.filter { trade in
                    let date = Self.date(daysAgo: trade.daysAgo)
                    return date >= window.from && date <= window.to
                }
                (status, body) = (.ok, Self.json(inWindow.map(Self.tradeJSON)))
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
            StubIBKRGateway(eventLoop: eventLoop, state: state)
        }

        static func date(daysAgo: Int) -> Date {
            Calendar(identifier: .gregorian).startOfDay(for: Date().addingTimeInterval(-Double(daysAgo) * 86400))
        }

        private static func window(of url: URI) -> (from: Date, to: Date) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            var from = Date.distantPast
            var to = Date.distantFuture
            for item in URLComponents(string: url.string)?.queryItems ?? [] {
                guard let value = item.value, let parsed = formatter.date(from: value) else { continue }
                if item.name == "from" {
                    from = parsed
                }
                if item.name == "to" {
                    to = parsed.addingTimeInterval(86399)
                }
            }
            return (from, to)
        }

        private static func json(_ objects: [[String: Any]]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: objects) else { return "[]" }
            return String(bytes: data, encoding: .utf8) ?? "[]"
        }

        private static func positionJSON(_ position: StubPosition) -> [String: Any] {
            var object: [String: Any] = [
                "ticker": position.ticker,
                "position": position.quantity,
                "avgCost": position.avgCost,
                "currency": "USD",
            ]
            if let assetClass = position.assetClass {
                object["assetClass"] = assetClass
            }
            return object
        }

        private static func tradeJSON(_ trade: StubTrade) -> [String: Any] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            var object: [String: Any] = [
                "transactionID": trade.id,
                "symbol": trade.symbol,
                "type": trade.type,
                "quantity": trade.quantity,
                "price": trade.price,
                "currency": "USD",
                "date": formatter.string(from: date(daysAgo: trade.daysAgo)),
            ]
            if let assetClass = trade.assetClass {
                object["assetClass"] = assetClass
            }
            return object
        }
    }

    private func sync(_ app: Application, connection: BrokerConnection, userId: UUID, state: StubState) async throws {
        app.clients.use { app in StubIBKRGateway(eventLoop: app.eventLoopGroup.next(), state: state) }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        _ = try await IBKRBrokerSyncService(gatewayClient: IBKRBrokerGatewayClient(baseURL: "http://ibkr.test/v1/api", defaultCurrency: "USD"))
            .sync(connection: connection, userId: userId, on: req)
    }

    private func makeConnection(userId: UUID, on db: any Database) async throws -> BrokerConnection {
        let connection = BrokerConnection(userId: userId, provider: "ibkr", status: "connected")
        try await connection.create(on: db)
        return connection
    }

    private func ledger(userId: UUID, instrumentId: UUID, on db: any Database) async throws -> (lots: [Lot], disposals: [LotDisposal]) {
        let account = try #require(try await Account.query(on: db).filter(\.$userId == userId).filter(\.$broker == "ibkr").first())
        let lots = try await Lot.query(on: db)
            .filter(\.$accountId == account.requireID())
            .filter(\.$instrumentId == instrumentId)
            .all()
        let lotIDs = lots.compactMap(\.id)
        let disposals = lotIDs.isEmpty ? [] : try await LotDisposal.query(on: db).filter(\.$lotId ~~ lotIDs).all()
        return (lots, disposals)
    }

    private func openQuantity(_ lots: [Lot]) -> Double {
        lots.reduce(0) { $0 + $1.remainingQuantity }
    }

    // MARK: - Tests

    @Test("open lot quantity equals the broker position, with no snapshot lot on top of the trade lots")
    func firstSyncDoesNotDoubleCount() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let symbol = "LDA\(UUID().uuidString.prefix(4))".uppercased()
            let instrumentId = try await makeInstrument(symbol, on: app.db)
            let connection = try await makeConnection(userId: userId, on: app.db)
            let state = StubState()
            state.positions = [StubPosition(ticker: symbol, quantity: 9, avgCost: 106.67)]
            state.trades = [
                StubTrade(id: "\(symbol)-b1", symbol: symbol, type: "BUY", quantity: 10, price: 100, daysAgo: 40),
                StubTrade(id: "\(symbol)-b2", symbol: symbol, type: "BUY", quantity: 5, price: 120, daysAgo: 20),
                StubTrade(id: "\(symbol)-s1", symbol: symbol, type: "SELL", quantity: -6, price: 150, daysAgo: 10),
            ]

            try await sync(app, connection: connection, userId: userId, state: state)

            let (lots, disposals) = try await ledger(userId: userId, instrumentId: instrumentId, on: app.db)
            #expect(lots.count == 2)
            #expect(lots.allSatisfy { $0.openTransactionId != nil })
            #expect(abs(openQuantity(lots) - 9) < 0.000_001)
            #expect(disposals.count == 1)
        }
    }

    @Test("a later sync whose window holds no trades keeps the lots and the realized disposal")
    func laterSyncKeepsRealizedHistory() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let symbol = "LDB\(UUID().uuidString.prefix(4))".uppercased()
            let instrumentId = try await makeInstrument(symbol, on: app.db)
            let connection = try await makeConnection(userId: userId, on: app.db)
            let state = StubState()
            state.positions = [StubPosition(ticker: symbol, quantity: 9, avgCost: 106.67)]
            state.trades = [
                StubTrade(id: "\(symbol)-b1", symbol: symbol, type: "BUY", quantity: 10, price: 100, daysAgo: 40),
                StubTrade(id: "\(symbol)-b2", symbol: symbol, type: "BUY", quantity: 5, price: 120, daysAgo: 20),
                StubTrade(id: "\(symbol)-s1", symbol: symbol, type: "SELL", quantity: -6, price: 150, daysAgo: 10),
            ]

            try await sync(app, connection: connection, userId: userId, state: state)
            let first = try await ledger(userId: userId, instrumentId: instrumentId, on: app.db)

            // lastSyncedAt is now set, so this window covers only the overlap days.
            try await sync(app, connection: connection, userId: userId, state: state)
            let second = try await ledger(userId: userId, instrumentId: instrumentId, on: app.db)

            #expect(Set(second.lots.compactMap(\.id)) == Set(first.lots.compactMap(\.id)))
            #expect(second.disposals.count == 1)
            #expect(second.disposals.first?.id == first.disposals.first?.id)
            #expect(abs(openQuantity(second.lots) - 9) < 0.000_001)
        }
    }

    @Test("a position with no recorded trades keeps one opening lot across syncs instead of failing on a duplicate opening transaction")
    func openingBalanceSurvivesRepeatSyncs() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let symbol = "LDC\(UUID().uuidString.prefix(4))".uppercased()
            let instrumentId = try await makeInstrument(symbol, on: app.db)
            let connection = try await makeConnection(userId: userId, on: app.db)
            let state = StubState()
            state.positions = [StubPosition(ticker: symbol, quantity: 10, avgCost: 50)]

            try await sync(app, connection: connection, userId: userId, state: state)
            try await sync(app, connection: connection, userId: userId, state: state)

            let (lots, _) = try await ledger(userId: userId, instrumentId: instrumentId, on: app.db)
            #expect(lots.count == 1)
            #expect(abs(openQuantity(lots) - 10) < 0.000_001)
            let openings = try await Transaction.query(on: app.db)
                .filter(\.$instrumentId == instrumentId)
                .filter(\.$type == "OPENING_BALANCE")
                .count()
            #expect(openings == 1)
        }
    }

    @Test("an account already damaged by snapshot syncs is rebuilt from its stored trades")
    func repairsSnapshotDamagedLedger() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let symbol = "LDD\(UUID().uuidString.prefix(4))".uppercased()
            let instrumentId = try await makeInstrument(symbol, on: app.db)
            let connection = try await makeConnection(userId: userId, on: app.db)
            let state = StubState()
            state.positions = [StubPosition(ticker: symbol, quantity: 9, avgCost: 106.67)]
            state.trades = [
                StubTrade(id: "\(symbol)-b1", symbol: symbol, type: "BUY", quantity: 10, price: 100, daysAgo: 40),
                StubTrade(id: "\(symbol)-b2", symbol: symbol, type: "BUY", quantity: 5, price: 120, daysAgo: 20),
                StubTrade(id: "\(symbol)-s1", symbol: symbol, type: "SELL", quantity: -6, price: 150, daysAgo: 10),
            ]
            try await sync(app, connection: connection, userId: userId, state: state)

            // What the old sync left behind: every lot (and so every disposal)
            // replaced by one snapshot lot with no opening trade.
            let account = try #require(try await Account.query(on: app.db).filter(\.$userId == userId).filter(\.$broker == "ibkr").first())
            for lot in try await ledger(userId: userId, instrumentId: instrumentId, on: app.db).lots {
                try await lot.delete(on: app.db)
            }
            try await Lot(
                accountId: account.requireID(),
                instrumentId: instrumentId,
                openDate: Date(),
                openQuantity: 9,
                remainingQuantity: 9,
                openPrice: 106.67,
                currency: "USD",
                status: "open"
            ).create(on: app.db)

            try await sync(app, connection: connection, userId: userId, state: state)

            let (lots, disposals) = try await ledger(userId: userId, instrumentId: instrumentId, on: app.db)
            #expect(lots.count == 2)
            #expect(lots.allSatisfy { $0.openTransactionId != nil })
            #expect(abs(openQuantity(lots) - 9) < 0.000_001)
            #expect(disposals.count == 1)
            #expect(abs(disposals.reduce(0) { $0 + $1.quantity } - 6) < 0.000_001)
        }
    }

    @Test("an option position or trade on a symbol leaves that symbol's stock holding and lots alone")
    func derivativesDoNotOverwriteTheirUnderlying() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let symbol = "LDE\(UUID().uuidString.prefix(4))".uppercased()
            let instrumentId = try await makeInstrument(symbol, on: app.db)
            let connection = try await makeConnection(userId: userId, on: app.db)
            let state = StubState()
            state.positions = [
                StubPosition(ticker: symbol, quantity: 5, avgCost: 100, assetClass: "STK"),
                StubPosition(ticker: symbol, quantity: 1, avgCost: 250, assetClass: "OPT"),
            ]
            state.trades = [
                StubTrade(id: "\(symbol)-b1", symbol: symbol, type: "BUY", quantity: 5, price: 100, daysAgo: 30, assetClass: "STK"),
                StubTrade(id: "\(symbol)-o1", symbol: symbol, type: "BUY", quantity: 1, price: 2.5, daysAgo: 5, assetClass: "OPT"),
            ]

            try await sync(app, connection: connection, userId: userId, state: state)

            let stock = try #require(try await Stock.query(on: app.db).filter(\.$userId == userId).filter(\.$symbol == symbol).first())
            #expect(stock.shares == 5)
            let (lots, _) = try await ledger(userId: userId, instrumentId: instrumentId, on: app.db)
            #expect(abs(openQuantity(lots) - 5) < 0.000_001)
            let trades = try await Transaction.query(on: app.db).filter(\.$instrumentId == instrumentId).all()
            #expect(trades.allSatisfy { $0.externalId != "\(symbol)-o1" })
        }
    }
}
