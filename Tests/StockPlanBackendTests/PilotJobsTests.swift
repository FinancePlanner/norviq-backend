import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

private actor CallLog {
    var slugsSeen: [String] = []
    func record(_ kind: String) {
        slugsSeen.append(kind)
    }
}

private struct CountingSource: PilotDisclosureSource {
    let log: CallLog
    func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput] {
        await log.record(pilot.cik ?? pilot.kind.rawValue)
        return []
    }
}

@Suite("PilotJobs", .serialized)
struct PilotJobsTests {
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

    private func makeHypothetical(userId: UUID, on db: any Database) async throws -> UUID {
        let list = PortfolioList(userId: userId, name: "Sim \(UUID().uuidString.prefix(6))", mode: "hypothetical")
        try await list.create(on: db)
        return try list.requireID()
    }

    private let now = Date(timeIntervalSince1970: 1_790_812_800)

    private func makePilot(on db: any Database) async throws -> Pilot {
        let pilot = Pilot(kind: .politician, slug: "p-\(UUID().uuidString.prefix(6))", displayName: "Test Pilot", chamber: "house", nameAliases: ["Test Pilot"])
        try await pilot.create(on: db)
        return pilot
    }

    @Test("mirror job catches a lagging follow up to the latest version and writes one snapshot per day")
    func catchUpAndSnapshot() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let account = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: app.db)
            try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: 1000, asOf: now).create(on: app.db)
            let follow = try PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: 1000)
            try await follow.create(on: app.db)
            try await PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: now, weights: ["AAPL": 1.0], skippedPuts: 0).create(on: app.db)
            try await PilotBookVersion(pilotId: pilot.requireID(), version: 2, computedAt: now, weights: ["MSFT": 1.0], skippedPuts: 0).create(on: app.db)

            let mirror = PilotMirrorService(quote: { _ in 100 }, instrument: { _ in nil }, watchlistLimit: { _, _, _ in })
            let job = PilotMirrorJob()
            await job.runOnceAsLeader(app, mirror: mirror, now: now)
            await job.runOnceAsLeader(app, mirror: mirror, now: now)

            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 2)
            let symbols = try await Stock.query(on: app.db).filter(\.$portfolioListId == listId).all().map(\.symbol)
            #expect(symbols == ["MSFT"])
            #expect(try await PilotFollowSnapshot.query(on: app.db).filter(\.$followId == follow.requireID()).count() == 1)
        }
    }

    @Test("ingestion job reads a fund at most once a day; politicians every run")
    func fundCadence() async throws {
        try await withApp { app in
            let fund = Pilot(kind: .fund, slug: "f-\(UUID().uuidString.prefix(6))", displayName: "Fund", cik: "0000000001")
            fund.lastIngestedAt = Date().addingTimeInterval(-3600)
            try await fund.create(on: app.db)
            let politician = try await makePilot(on: app.db)
            let calls = CallLog()
            let stub = CountingSource(log: calls)
            await PilotIngestionJob().runOnceAsLeader(app, service: PilotIngestionService(politicians: stub, funds: stub))
            let seen = await calls.slugsSeen
            // Seeded pilots are active too; assert on this test's fund by CIK.
            #expect(seen.contains("politician"))
            #expect(!seen.contains("0000000001"))
            _ = politician
        }
    }

    @Test("paused follows are not mirrored")
    func pausedSkipped() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let follow = try PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: 1000)
            follow.status = PilotFollowStatus.paused.rawValue
            try await follow.create(on: app.db)
            try await PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: now, weights: ["AAPL": 1.0], skippedPuts: 0).create(on: app.db)
            await PilotMirrorJob().runOnceAsLeader(app, mirror: PilotMirrorService(quote: { _ in 100 }, instrument: { _ in nil }, watchlistLimit: { _, _, _ in }), now: now)
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 0)
        }
    }
}
