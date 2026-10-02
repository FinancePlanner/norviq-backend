import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// M7: a pilot-followed watchlist is never the default, and the default is never a follow target.
extension StagingGatesTests {
    @Test("a followed watchlist is never promoted to default; a fresh Main Watchlist is created")
    func followedWatchlistIsNeverDefault() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let pilot = try await seededBook(on: app.db)
            let feed = WatchlistList(userId: userId, name: "Main Watchlist")
            try await feed.create(on: app.db)
            try await PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .watchlist, watchlistListId: feed.requireID()).create(on: app.db)

            let defaultId = try await ensureDefaultWatchlistListId(userId: userId, on: app.db)

            #expect(defaultId != feed.id)
            let created = try #require(try await WatchlistList.find(defaultId, on: app.db))
            #expect(created.isDefault)
            #expect(created.name == "Main Watchlist 2")
            #expect(try await WatchlistList.find(feed.requireID(), on: app.db)?.isDefault == false)

            // A followed watchlist already flagged default is demoted.
            feed.isDefault = true
            try await feed.save(on: app.db)
            created.isDefault = false
            try await created.save(on: app.db)
            #expect(try await ensureDefaultWatchlistListId(userId: userId, on: app.db) == created.id)
            #expect(try await WatchlistList.find(feed.requireID(), on: app.db)?.isDefault == false)

            // Without follows the oldest watchlist is still promoted.
            let (_, other) = try await registerTestUser(app: app)
            let oldest = WatchlistList(userId: other, name: "Ideas")
            try await oldest.create(on: app.db)
            #expect(try await ensureDefaultWatchlistListId(userId: other, on: app.db) == oldest.id)
        }
    }

    @Test("the default watchlist is not a follow target")
    func defaultWatchlistIsNotAFollowTarget() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let pilot = try await seededBook(on: app.db)
            let main = WatchlistList(userId: userId, name: "Main Watchlist", isDefault: true)
            try await main.create(on: app.db)
            do {
                _ = try await followService.create(
                    PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .watchlist, portfolioListId: nil, watchlistListId: main.requireID().uuidString, startingCapital: nil),
                    userId: userId, entitlement: EntitlementSnapshot(userId: userId, level: "pro"), now: Date(), on: app.db
                )
                Issue.record("followed into the default watchlist")
            } catch let error as any AbortError {
                #expect(error.status == .unprocessableEntity, "\(error.reason)")
            }
            #expect(try await PilotFollow.query(on: app.db).filter(\.$userId == userId).count() == 0)
        }
    }
}
