import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

/// G2: resolving the default portfolio never promotes a pilot portfolio.
extension StagingGatesTests {
    @Test("a user whose only list is a pilot portfolio gets a fresh actual Main list as default")
    func onlyPilotListGetsFreshDefault() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)

            let defaultId = try await ensureDefaultPortfolioListId(userId: userId, on: app.db)

            #expect(defaultId != seeded.listId)
            let created = try #require(try await PortfolioList.find(defaultId, on: app.db))
            #expect(created.isDefault)
            #expect(created.mode == PortfolioMode.actual.rawValue)
            #expect(created.name == "Main Portfolio")
            #expect(try await PortfolioList.find(seeded.listId, on: app.db)?.isDefault == false)
            // Idempotent: the next resolution reuses it.
            #expect(try await ensureDefaultPortfolioListId(userId: userId, on: app.db) == defaultId)

            // The portfolio list endpoint resolves the default the same way.
            try await app.testing().test(.GET, "v1/portfolios", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res async throws in
                #expect(res.status == .ok)
            }
            #expect(try await PortfolioList.query(on: app.db).filter(\.$userId == userId).filter(\.$isDefault == true).all().map(\.id) == [defaultId])
        }
    }

    @Test("an older pilot portfolio is skipped; the oldest unfollowed list is promoted")
    func olderPilotListIsSkipped() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            let plain = PortfolioList(userId: userId, name: "Later list", mode: "hypothetical")
            try await plain.create(on: app.db)

            #expect(try await ensureDefaultPortfolioListId(userId: userId, on: app.db) == plain.id)
            #expect(try await PortfolioList.find(seeded.listId, on: app.db)?.isDefault == false)
            #expect(try await PortfolioList.query(on: app.db).filter(\.$userId == userId).count() == 2)
        }
    }

    @Test("without pilot follows the oldest list is still promoted, hypothetical or not")
    func unfollowedPromotionUnchanged() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let oldest = PortfolioList(userId: userId, name: "Sandbox", mode: "hypothetical")
            try await oldest.create(on: app.db)
            let newer = PortfolioList(userId: userId, name: "Real")
            try await newer.create(on: app.db)

            #expect(try await ensureDefaultPortfolioListId(userId: userId, on: app.db) == oldest.id)
            #expect(try await PortfolioList.find(oldest.requireID(), on: app.db)?.isDefault == true)

            let (_, emptyUser) = try await registerTestUser(app: app)
            let createdId = try await ensureDefaultPortfolioListId(userId: emptyUser, on: app.db)
            let created = try #require(try await PortfolioList.find(createdId, on: app.db))
            #expect(created.name == "Main Portfolio")
            #expect(created.isDefault)
        }
    }

    @Test("a pilot portfolio already flagged default is demoted, and the new Main avoids its name")
    func legacyFollowedDefaultIsDemoted() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let seeded = try await seedFollowedList(userId: userId, name: "Main Portfolio", on: app.db)
            let pilotList = try #require(try await PortfolioList.find(seeded.listId, on: app.db))
            pilotList.isDefault = true
            try await pilotList.save(on: app.db)

            let defaultId = try await ensureDefaultPortfolioListId(userId: userId, on: app.db)

            #expect(defaultId != seeded.listId)
            #expect(try await PortfolioList.find(seeded.listId, on: app.db)?.isDefault == false)
            let created = try #require(try await PortfolioList.find(defaultId, on: app.db))
            #expect(created.isDefault)
            #expect(created.mode == PortfolioMode.actual.rawValue)
            #expect(created.name == "Main Portfolio 2")
        }
    }
}
