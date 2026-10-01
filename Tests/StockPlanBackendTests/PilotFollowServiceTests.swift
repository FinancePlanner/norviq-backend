import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("PilotFollowService", .serialized)
struct PilotFollowServiceTests {
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

    private let now = Date(timeIntervalSince1970: 1_790_812_800)

    private func makePilot(on db: any Database) async throws -> Pilot {
        let pilot = Pilot(kind: .politician, slug: "p-\(UUID().uuidString.prefix(6))", displayName: "Test Pilot", chamber: "house", nameAliases: ["Test Pilot"])
        try await pilot.create(on: db)
        return pilot
    }

    private func entitlement(_ userId: UUID, pro: Bool) -> EntitlementSnapshot {
        EntitlementSnapshot(userId: userId, level: pro ? "pro" : "free")
    }

    private func seededPilot(on db: any Database) async throws -> Pilot {
        let pilot = try await makePilot(on: db)
        try await PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: now, weights: ["AAPL": 1.0], skippedPuts: 0).create(on: db)
        return pilot
    }

    private var followService: PilotFollowService {
        PilotFollowService(mirror: PilotMirrorService(quote: { _ in 100 }, instrument: { _ in nil }, watchlistLimit: { _, _, _ in }))
    }

    @Test("pro: portfolio follow creates a hypothetical portfolio funded with starting capital and applies the book")
    func createsPortfolio() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            let follow = try await followService.create(
                PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: nil, watchlistListId: nil, startingCapital: 10000),
                userId: userId, entitlement: entitlement(userId, pro: true), now: now, on: app.db
            )
            let list = try #require(try await PortfolioList.find(follow.portfolioListId, on: app.db))
            #expect(list.mode == "hypothetical")
            #expect(list.isDefault == false)
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 1)
            #expect(try await Stock.query(on: app.db).filter(\.$portfolioListId == list.requireID()).first()?.shares == 100)
        }
    }

    @Test("free: portfolio target is refused; one watchlist follow allowed, second refused")
    func freeGating() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            let other = try await seededPilot(on: app.db)
            let free = entitlement(userId, pro: false)
            await #expect(throws: BillingUpgradeRequiredError.self) {
                try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: nil, watchlistListId: nil, startingCapital: 1000), userId: userId, entitlement: free, now: now, on: app.db)
            }
            _ = try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .watchlist, portfolioListId: nil, watchlistListId: nil, startingCapital: nil), userId: userId, entitlement: free, now: now, on: app.db)
            await #expect(throws: BillingUpgradeRequiredError.self) {
                try await followService.create(PilotFollowCreateRequest(pilotSlug: other.slug, targetKind: .watchlist, portfolioListId: nil, watchlistListId: nil, startingCapital: nil), userId: userId, entitlement: free, now: now, on: app.db)
            }
        }
    }

    @Test("actual, default and non-empty portfolios are rejected with 422 and nothing is written")
    func rejectsNonEmptyAndActualTargets() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            let pro = entitlement(userId, pro: true)
            let actual = PortfolioList(userId: userId, name: "Main", isDefault: true, mode: "actual")
            try await actual.create(on: app.db)
            let busy = PortfolioList(userId: userId, name: "Busy", mode: "hypothetical")
            try await busy.create(on: app.db)
            try await Stock(userId: userId, portfolioListId: busy.requireID(), symbol: "KO", shares: 1, buyPrice: 1, buyDate: now).create(on: app.db)

            for target in [actual, busy] {
                do {
                    _ = try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: target.requireID().uuidString, watchlistListId: nil, startingCapital: 1000), userId: userId, entitlement: pro, now: now, on: app.db)
                    Issue.record("expected 422 for \(target.name)")
                } catch let error as Abort {
                    #expect(error.status == .unprocessableEntity)
                }
            }
            #expect(try await PilotFollow.query(on: app.db).filter(\.$userId == userId).count() == 0)
        }
    }

    @Test("missing or non-positive starting capital is a 400 for portfolio targets")
    func capitalValidation() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            do {
                _ = try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: nil, watchlistListId: nil, startingCapital: 0), userId: userId, entitlement: entitlement(userId, pro: true), now: now, on: app.db)
                Issue.record("expected 400")
            } catch let error as Abort {
                #expect(error.status == .badRequest)
            }
        }
    }
}
