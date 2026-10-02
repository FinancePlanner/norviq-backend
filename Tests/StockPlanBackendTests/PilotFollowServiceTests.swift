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

    private func portfolioReq(_ pilot: Pilot, _ list: PortfolioList?) throws -> PilotFollowCreateRequest {
        try PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: list?.requireID().uuidString, watchlistListId: nil, startingCapital: 1000)
    }

    private func expect422(_ list: PortfolioList, pilot: Pilot, userId: UUID, on db: any Database, _ label: String) async throws {
        do {
            _ = try await followService.create(portfolioReq(pilot, list), userId: userId, entitlement: entitlement(userId, pro: true), now: now, on: db)
            Issue.record("expected 422 for \(label)")
        } catch let error as Abort {
            #expect(error.status == .unprocessableEntity, "\(label)")
        }
    }

    @Test("actual, default, archived and non-empty portfolios are rejected with 422 and nothing is written")
    func rejectsNonEmptyAndActualTargets() async throws {
        try await withApp { app in
            let db = app.db
            let userId = try await makeUser(on: db)
            let pilot = try await seededPilot(on: db)
            let actual = PortfolioList(userId: userId, name: "Real", mode: "actual")
            try await actual.create(on: db)
            let defaulted = PortfolioList(userId: userId, name: "Main", isDefault: true, mode: "hypothetical")
            try await defaulted.create(on: db)
            let archived = PortfolioList(userId: userId, name: "Old", mode: "hypothetical")
            archived.archivedAt = now
            try await archived.create(on: db)
            let busy = PortfolioList(userId: userId, name: "Busy", mode: "hypothetical")
            try await busy.create(on: db)
            try await Stock(userId: userId, portfolioListId: busy.requireID(), symbol: "KO", shares: 1, buyPrice: 1, buyDate: now).create(on: db)
            let cashOnly = PortfolioList(userId: userId, name: "CashOnly", mode: "hypothetical")
            try await cashOnly.create(on: db)
            try await PortfolioCashPositionRecord(portfolioId: cashOnly.requireID(), label: "Cash", currency: "USD", balance: 5, asOf: now).create(on: db)
            let taken = PortfolioList(userId: userId, name: "Taken", mode: "hypothetical")
            try await taken.create(on: db)
            let otherPilot = try await seededPilot(on: db)
            try await PilotFollow(userId: userId, pilotId: otherPilot.requireID(), targetKind: .portfolio, portfolioListId: taken.requireID(), startingCapital: 1).create(on: db)

            let accounts = try await Account.query(on: db).filter(\.$userId == userId).count()
            let cashes = try await CashBalance.query(on: db).count()
            let lists = try await PortfolioList.query(on: db).filter(\.$userId == userId).count()
            let follows = try await PilotFollow.query(on: db).filter(\.$userId == userId).count()

            for (list, label) in [(actual, "actual"), (defaulted, "default"), (archived, "archived"), (busy, "stock"), (cashOnly, "cash position"), (taken, "followed")] {
                try await expect422(list, pilot: pilot, userId: userId, on: db, label)
            }
            #expect(try await Account.query(on: db).filter(\.$userId == userId).count() == accounts)
            #expect(try await CashBalance.query(on: db).count() == cashes)
            #expect(try await PortfolioList.query(on: db).filter(\.$userId == userId).count() == lists)
            #expect(try await PilotFollow.query(on: db).filter(\.$userId == userId).count() == follows)
            let stock = try #require(try await Stock.query(on: db).filter(\.$portfolioListId == busy.requireID()).first())
            #expect(stock.symbol == "KO" && stock.shares == 1)
        }
    }

    @Test("duplicate follow of the same pilot into the same watchlist is a 409")
    func duplicateIsConflict() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            let pro = entitlement(userId, pro: true)
            let first = try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .watchlist, portfolioListId: nil, watchlistListId: nil, startingCapital: nil), userId: userId, entitlement: pro, now: now, on: app.db)
            do {
                _ = try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .watchlist, portfolioListId: nil, watchlistListId: first.watchlistListId?.uuidString, startingCapital: nil), userId: userId, entitlement: pro, now: now, on: app.db)
                Issue.record("expected 409")
            } catch let error as Abort {
                #expect(error.status == .conflict)
            }
        }
    }

    @Test("existing manual accounts and their real cash are never touched by a portfolio follow")
    func realAccountsUntouched() async throws {
        try await withApp { app in
            let db = app.db
            let userId = try await makeUser(on: db)
            let pilot = try await seededPilot(on: db)
            let main = PortfolioList(userId: userId, name: "Main", isDefault: true, mode: "actual")
            try await main.create(on: db)
            let legacy = Account(userId: userId, externalId: "manual-\(userId.uuidString.lowercased())", broker: "manual", displayName: "Manual", baseCurrency: "USD")
            try await legacy.create(on: db)
            try await CashBalance(accountId: legacy.requireID(), currency: "USD", balance: 777, asOf: now).create(on: db)
            let bound = try Account(userId: userId, externalId: "manual-main-\(userId.uuidString.lowercased())", broker: "manual", displayName: "Manual main", baseCurrency: "USD", portfolioId: main.requireID())
            try await bound.create(on: db)
            try await CashBalance(accountId: bound.requireID(), currency: "USD", balance: 555, asOf: now).create(on: db)

            let follow = try await followService.create(portfolioReq(pilot, nil), userId: userId, entitlement: entitlement(userId, pro: true), now: now, on: db)

            let legacyAfter = try #require(try await Account.find(legacy.requireID(), on: db))
            #expect(legacyAfter.portfolioId == nil)
            let boundAfter = try #require(try await Account.find(bound.requireID(), on: db))
            #expect(boundAfter.portfolioId == main.id)
            func cash(_ a: Account) async throws -> Double {
                try await CashBalance.query(on: db).filter(\.$accountId == a.requireID()).all().reduce(0) { $0 + $1.balance }
            }
            #expect(try await cash(legacy) == 777)
            #expect(try await cash(bound) == 555)

            let listId = try #require(follow.portfolioListId)
            let accounts = try await Account.query(on: db).filter(\.$portfolioId == listId).all()
            #expect(accounts.count == 1)
            let sim = try #require(accounts.first)
            #expect(sim.broker == "pilot")
            // 1000 capital, AAPL at weight 1.0 and price 100: fully invested.
            let stock = try #require(try await Stock.query(on: db).filter(\.$portfolioListId == listId).first())
            let simCash = try await cash(sim)
            #expect(simCash == 1000 - stock.shares * 100)
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
