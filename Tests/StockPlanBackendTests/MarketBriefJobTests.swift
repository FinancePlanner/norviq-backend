import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Market brief runner and job", .serialized)
struct MarketBriefJobTests {
    private let due = MarketBriefSchedule.Due(tradingDate: "2026-10-08", slot: .morning)
    /// Thursday 2026-10-08 08:30 Lisbon (WEST) = 07:30 UTC: inside the morning window.
    private let inWindow = Date(timeIntervalSince1970: 1_791_444_600)
    /// Same day 12:10 UTC = 13:10 Lisbon: no window.
    private let outOfWindow = Date(timeIntervalSince1970: 1_791_461_400)

    private func request(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    @Test("Runner generates once, then skips the existing slot without calling the generator")
    func runnerSkipsExisting() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator()
            let runner = MarketBriefRunner(generator: generator, repository: DatabaseMarketBriefRepository())
            let first = try await runner.run(due, replace: false, on: request(app))
            let second = try await runner.run(due, replace: false, on: request(app))
            #expect(first == .generated(degraded: false))
            #expect(second == .skippedExisting)
            #expect(generator.calls == 1)
        }
    }

    @Test("Replace regenerates an existing slot")
    func runnerReplace() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator()
            let runner = MarketBriefRunner(generator: generator, repository: DatabaseMarketBriefRepository())
            _ = try await runner.run(due, replace: false, on: request(app))
            let replaced = try await runner.run(due, replace: true, on: request(app))
            #expect(replaced == .generated(degraded: false))
            #expect(generator.calls == 2)
        }
    }

    @Test("A replica that loses the insert race reports skippedExisting, not a failure")
    func lostRaceIsSkip() async throws {
        try await MarketBriefFixtures.withApp { app in
            let repo = DatabaseMarketBriefRepository()
            // The other replica wrote the slot after our `exists` check would have run.
            let racing = RacingRepository(inner: repo, otherReplica: {
                try await repo.save(
                    MarketBriefLanguage.allCases.map { MarketBriefFixtures.response(language: $0.rawValue) },
                    model: "other", generatedAt: Date(), on: app.db
                )
            })
            let runner = MarketBriefRunner(generator: StubMarketBriefGenerator(), repository: racing)
            let outcome = try await runner.run(due, replace: false, on: request(app))
            #expect(outcome == .skippedExisting)
        }
    }

    @Test("Tick does nothing outside a window")
    func tickOutsideWindow() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator()
            app.marketBriefGenerator = generator
            await MarketBriefJob().tick(app, now: outOfWindow)
            #expect(generator.calls == 0)
        }
    }

    @Test("Tick stops retrying a slot after three failures")
    func tickAttemptCap() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator(error: Abort(.badGateway))
            app.marketBriefGenerator = generator
            let job = MarketBriefJob()
            for _ in 0 ..< 5 {
                await job.tick(app, now: inWindow)
            }
            #expect(generator.calls == MarketBriefJob.maxAttemptsPerSlot)
        }
    }

    @Test("Tick in window writes the slot once")
    func tickWrites() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator()
            app.marketBriefGenerator = generator
            let job = MarketBriefJob()
            await job.tick(app, now: inWindow)
            await job.tick(app, now: inWindow)
            #expect(generator.calls == 1)
            let written = try await app.marketBriefRepository.exists(tradingDate: "2026-10-08", slot: .morning, on: app.db)
            #expect(written)
        }
    }

    @Test("configure registers the operator command and leaves the feature off by default")
    func wiring() async throws {
        try await MarketBriefFixtures.withApp { app in
            #expect(app.marketBriefEnabled == false)
            #expect(app.marketBriefGenerator != nil)
            #expect(app.asyncCommands.commands["market-brief-generate"] != nil)
        }
    }
}

/// Reports "not there" from `exists`, then lets another replica write first.
private struct RacingRepository: MarketBriefRepository {
    let inner: DatabaseMarketBriefRepository
    let otherReplica: @Sendable () async throws -> Void

    func exists(tradingDate _: String, slot _: MarketBriefSlot, on _: any Database) async throws -> Bool {
        try await otherReplica()
        return false
    }

    func save(_ briefs: [MarketBriefResponse], model: String, generatedAt: Date, on db: any Database) async throws {
        try await inner.save(briefs, model: model, generatedAt: generatedAt, on: db)
    }

    func delete(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws {
        try await inner.delete(tradingDate: tradingDate, slot: slot, on: db)
    }

    func latest(language: String, on db: any Database) async throws -> MarketBriefResponse? {
        try await inner.latest(language: language, on: db)
    }

    func find(tradingDate: String, slot: MarketBriefSlot, language: String, on db: any Database) async throws -> MarketBriefResponse? {
        try await inner.find(tradingDate: tradingDate, slot: slot, language: language, on: db)
    }
}
