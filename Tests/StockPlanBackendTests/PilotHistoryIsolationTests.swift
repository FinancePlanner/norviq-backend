import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

private typealias TransactionList = [TransactionResponse]

/// Simulated pilot trades must stay out of the user's real trade history:
/// the transaction list, CSV export, badges and tax account options.
extension PilotControllerTests {
    @Test("pilot transactions stay out of the transaction list, export, badges and tax account options")
    func pilotTradesStayOutOfRealHistory() async throws {
        try await withApp { app in
            try await checkPilotTradesStayOut(app)
        }
    }

    private func checkPilotTradesStayOut(_ app: Application) async throws {
        do {
            let (token, userId) = try await registerTestUser(app: app)
            let suffix = UUID().uuidString.prefix(4).uppercased()
            let symbols: [String] = ["PA" + suffix, "PB" + suffix]
            var ids: [String: UUID] = [:]
            for symbol in symbols + ["KO"] {
                if let existing = try await Instrument.query(on: app.db).filter(\.$symbol == symbol).first() {
                    ids[symbol] = try existing.requireID()
                    continue
                }
                let instrument = Instrument(conid: "test:\(symbol):\(UUID().uuidString.prefix(6))", symbol: symbol, exchange: "TEST", currency: "USD")
                try await instrument.create(on: app.db)
                ids[symbol] = try instrument.requireID()
            }
            let resolved = ids

            // A followed portfolio whose first book version has executed.
            let pilot = Pilot(kind: .politician, slug: "p-\(UUID().uuidString.prefix(6).lowercased())", displayName: "Test Pilot", chamber: "house", nameAliases: ["Test Pilot"])
            try await pilot.create(on: app.db)
            let main = PortfolioList(userId: userId, name: "Main", isDefault: true, mode: "actual")
            try await main.create(on: app.db)
            let list = PortfolioList(userId: userId, name: "Pilot copy", mode: "hypothetical")
            try await list.create(on: app.db)
            let listId = try list.requireID()
            let pilotAccount = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: app.db)
            let pilotAccountId = try pilotAccount.requireID()
            try await CashBalance(accountId: pilotAccountId, currency: "USD", balance: 10000, asOf: Date()).create(on: app.db)
            let follow = try PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: 10000)
            try await follow.create(on: app.db)
            let version = try PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: Date(), weights: [symbols[0]: 0.5, symbols[1]: 0.5], skippedPuts: 0)
            try await version.create(on: app.db)
            let mirror = PilotMirrorService(quote: { _ in 100.0 }, instrument: { symbol in resolved[symbol] }, watchlistLimit: { _, _, _ in })
            #expect(try await mirror.apply(follow: follow, pilot: pilot, version: version, previous: nil, now: Date(), on: app.db))
            #expect(try await Transaction.query(on: app.db).filter(\.$accountId == pilotAccountId).count() == 2)

            // One real, hand-recorded trade on the user's main portfolio.
            var manual: TransactionResponse?
            try await app.testing().test(.POST, "v1/transactions", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateTransactionRequest(symbol: "KO", type: "buy", quantity: 3, price: 60, currency: nil, tradeDate: "2026-04-11", settleDate: nil, fees: nil, portfolioListId: nil))
            }, afterResponse: { res async throws in
                #expect(res.status == .created, "\(res.body.string)")
                manual = try res.content.decode(TransactionResponse.self)
            })
            let manualRow = try #require(manual)

            var listed: [TransactionResponse] = []
            try await app.testing().test(.GET, "v1/transactions", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                listed = try res.content.decode(TransactionList.self)
            })
            #expect(listed.map(\.id) == [manualRow.id])
            #expect(listed.allSatisfy { $0.accountId != pilotAccountId.uuidString })

            let exported = try await ExportService(repository: app.dataExportRepository, application: app)
                .getTransactionRows(userId: userId, startDate: nil, endDate: nil, on: app.db)
            #expect(exported.map(\.id) == [manualRow.id])

            var taxContext: TaxProfileContextResponse?
            try await app.testing().test(.GET, "v1/tax/profile/context", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok, "\(res.body.string)")
                taxContext = try res.content.decode(TaxProfileContextResponse.self)
            })
            let options = try #require(taxContext).accounts
            #expect(!options.isEmpty)
            #expect(options.allSatisfy { $0.id != pilotAccountId.uuidString && $0.broker != PilotAccountResolver.broker })

            // Only the one real buy counts; the two simulated buys and the
            // two simulated holdings do not.
            var badges: BadgesListResponse?
            try await app.testing().test(.GET, "v1/badges", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                badges = try res.content.decode(BadgesListResponse.self)
            })
            let payload = try #require(badges)
            let firstPurchase = try #require(payload.badges.first { $0.type == .firstPurchase })
            #expect(firstPurchase.currentCount == 1)
        }
    }
}
