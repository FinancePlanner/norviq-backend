import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// I1: after a follow stops, its portfolio can be deleted; the pilot account,
/// its cash and trades, and the simulated stocks go with it. Also the shared
/// helpers the other fix-round tests use.
extension StagingGatesTests {
    var followService: PilotFollowService {
        PilotFollowService(mirror: PilotMirrorService(quote: { _ in 100 }, instrument: { _ in nil }, watchlistLimit: { _, _, _ in }))
    }

    func seededBook(on db: any Database) async throws -> Pilot {
        let pilot = Pilot(kind: .politician, slug: "gb-\(UUID().uuidString.prefix(8).lowercased())", displayName: "Gate Book", chamber: "house", nameAliases: ["Gate Book"])
        try await pilot.create(on: db)
        try await PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: Date(), weights: ["AAPL": 1.0], skippedPuts: 0).create(on: db)
        return pilot
    }

    /// A followed portfolio whose follow was then stopped, with a recorded
    /// simulated trade on its pilot account.
    private func seedUnfollowedPilotList(userId: UUID, on db: any Database) async throws -> FollowedList {
        let seeded = try await seedFollowedList(userId: userId, on: db)
        let instrument = try await seedInstrument(symbol: "AAPL", on: db)
        try await Transaction(accountId: seeded.pilotAccount.requireID(), instrumentId: instrument.requireID(), externalId: "pilot:\(UUID().uuidString)", type: "buy", quantity: 5, price: 100, currency: "USD", tradeDate: Date()).create(on: db)
        // What DELETE /v1/pilot-follows/{id} does.
        try await seeded.follow.delete(on: db)
        return seeded
    }

    private func expectPilotLeftoversGone(_ seeded: FollowedList, on db: any Database) async throws {
        let accountId = try seeded.pilotAccount.requireID()
        #expect(try await PortfolioList.find(seeded.listId, on: db) == nil)
        #expect(try await Account.find(accountId, on: db) == nil)
        #expect(try await CashBalance.query(on: db).filter(\.$accountId == accountId).count() == 0)
        #expect(try await Transaction.query(on: db).filter(\.$accountId == accountId).count() == 0)
        #expect(try await Stock.find(seeded.stockId, on: db) == nil)
    }

    // MARK: - I1

    @Test("after unfollowing, DELETE /v1/portfolios/{id} removes the list and its pilot account, cash, trades and simulated stocks")
    func unfollowedPilotPortfolioCanBeDeleted() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let followed = try await seedFollowedList(userId: userId, on: app.db)
            try await app.testing().test(.DELETE, "v1/portfolios/\(followed.listId)", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res async throws in
                #expect(res.status == .conflict, "still followed: \(res.status) \(res.body.string)")
            }
            #expect(try await PortfolioList.find(followed.listId, on: app.db) != nil)

            let seeded = try await seedUnfollowedPilotList(userId: userId, on: app.db)
            try await app.testing().test(.DELETE, "v1/portfolios/\(seeded.listId)", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res async throws in
                #expect(res.status == .noContent, "\(res.status) \(res.body.string)")
            }
            try await expectPilotLeftoversGone(seeded, on: app.db)
        }
    }

    @Test("after unfollowing, the legacy list delete removes the pilot leftovers instead of merging them into the default")
    func unfollowedPilotPortfolioLegacyDelete() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let main = PortfolioList(userId: userId, name: "Main", isDefault: true)
            try await main.create(on: app.db)
            let seeded = try await seedUnfollowedPilotList(userId: userId, on: app.db)
            try await app.testing().test(.DELETE, "v1/portfolio/lists/\(seeded.listId)", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res async throws in
                #expect(res.status == .noContent, "\(res.status) \(res.body.string)")
            }
            try await expectPilotLeftoversGone(seeded, on: app.db)
            #expect(try await stockSnapshot(listId: main.requireID(), on: app.db).isEmpty)
        }
    }

    @Test("a real account still blocks deleting an unfollowed pilot portfolio, on both routes")
    func realAccountStillBlocksDelete() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let main = PortfolioList(userId: userId, name: "Main", isDefault: true)
            try await main.create(on: app.db)
            let seeded = try await seedUnfollowedPilotList(userId: userId, on: app.db)
            let manual = Account(userId: userId, externalId: "gate-manual-\(UUID().uuidString)", broker: "manual", displayName: "Manual", baseCurrency: "USD", portfolioId: seeded.listId)
            try await manual.create(on: app.db)
            for path in ["v1/portfolios/\(seeded.listId)", "v1/portfolio/lists/\(seeded.listId)"] {
                try await app.testing().test(.DELETE, path, beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res async throws in
                    #expect(res.status == .conflict, "\(path): \(res.status) \(res.body.string)")
                    #expect(res.body.string.contains("Move connected accounts"), "\(path): \(res.body.string)")
                }
            }
            #expect(try await PortfolioList.find(seeded.listId, on: app.db) != nil)
            #expect(try await Account.find(seeded.pilotAccount.requireID(), on: app.db) != nil)
            #expect(try await Stock.find(seeded.stockId, on: app.db) != nil)
        }
    }
}
