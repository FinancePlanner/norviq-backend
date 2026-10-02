import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Pilot ingestion", .serialized)
struct PilotIngestionServiceTests {
    private let now = Date(timeIntervalSince1970: 1_790_812_800)

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

    private func makePilot(on db: any Database) async throws -> Pilot {
        let pilot = Pilot(kind: .politician, slug: "p-\(UUID().uuidString.prefix(6))", displayName: "Test Pilot", chamber: "house", nameAliases: ["Test Pilot"])
        try await pilot.create(on: db)
        return pilot
    }

    private struct StubSource: PilotDisclosureSource {
        let rows: [PilotDisclosureInput]
        func disclosures(for _: PilotSourceIdentity) async throws -> [PilotDisclosureInput] {
            rows
        }
    }

    private func buy(_ key: String, _ symbol: String, _ amount: Double) -> PilotDisclosureInput {
        PilotDisclosureInput(sourceKey: key, symbol: symbol, side: .buy, instrument: .stock, transactionDate: "2026-06-01", disclosureDate: "2026-07-01", amountMin: amount, amountMax: amount, shares: nil, marketValue: nil, period: nil)
    }

    @Test("first ingest writes version 1; the same rows again write nothing")
    func idempotent() async throws {
        try await withApp { app in
            let pilot = try await makePilot(on: app.db)
            let service = PilotIngestionService(politicians: StubSource(rows: [buy("a", "AAPL", 1000), buy("b", "MSFT", 3000)]), funds: nil)
            #expect(try await service.ingest(pilot: pilot, now: now, on: app.db) == .newVersion(1))
            #expect(try await service.ingest(pilot: pilot, now: now, on: app.db) == .unchanged)
            #expect(try await PilotDisclosureRecord.query(on: app.db).filter(\.$pilotId == pilot.requireID()).count() == 2)
            let v1 = try #require(try await PilotBookVersion.query(on: app.db).filter(\.$pilotId == pilot.requireID()).first())
            #expect(v1.weights == ["AAPL": 0.25, "MSFT": 0.75])
            let reloaded = try #require(try await Pilot.find(pilot.requireID(), on: app.db))
            #expect(reloaded.lastIngestedAt == now)
        }
    }

    @Test("a new disclosure writes the next version")
    func newVersion() async throws {
        try await withApp { app in
            let pilot = try await makePilot(on: app.db)
            _ = try await PilotIngestionService(politicians: StubSource(rows: [buy("a", "AAPL", 1000)]), funds: nil).ingest(pilot: pilot, now: now, on: app.db)
            let outcome = try await PilotIngestionService(politicians: StubSource(rows: [buy("a", "AAPL", 1000), buy("c", "KO", 1000)]), funds: nil).ingest(pilot: pilot, now: now, on: app.db)
            #expect(outcome == .newVersion(2))
            let v2 = try #require(try await PilotBookVersion.query(on: app.db).filter(\.$pilotId == pilot.requireID()).filter(\.$version == 2).first())
            #expect(v2.weights == ["AAPL": 0.5, "KO": 0.5])
        }
    }

    private func hold(_ key: String, _ symbol: String, _ value: Double, _ period: String) -> PilotDisclosureInput {
        PilotDisclosureInput(sourceKey: key, symbol: symbol, side: .hold, instrument: .stock, transactionDate: nil, disclosureDate: nil, amountMin: nil, amountMax: nil, shares: nil, marketValue: value, period: period)
    }

    @Test("a fund book uses the latest period only")
    func fundLatestPeriod() async throws {
        try await withApp { app in
            let pilot = Pilot(kind: .fund, slug: "f-\(UUID().uuidString.prefix(6))", displayName: "Fund", cik: "0000000001")
            try await pilot.create(on: app.db)
            let rows = [hold("o1", "OLD", 500, "2026-03-31"), hold("n1", "AAPL", 300, "2026-06-30"), hold("n2", "KO", 100, "2026-06-30")]
            let outcome = try await PilotIngestionService(politicians: StubSource(rows: []), funds: StubSource(rows: rows)).ingest(pilot: pilot, now: now, on: app.db)
            #expect(outcome == .newVersion(1))
            let v1 = try #require(try await PilotBookVersion.query(on: app.db).filter(\.$pilotId == pilot.requireID()).first())
            #expect(v1.weights == ["AAPL": 0.75, "KO": 0.25])
        }
    }

    @Test("an empty book stores the rows and stamps lastIngestedAt but writes no version")
    func emptyBook() async throws {
        try await withApp { app in
            let pilot = try await makePilot(on: app.db)
            let sell = PilotDisclosureInput(sourceKey: "s", symbol: "AAPL", side: .sell, instrument: .stock, transactionDate: "2026-06-01", disclosureDate: "2026-07-01", amountMin: 1000, amountMax: 1000, shares: nil, marketValue: nil, period: nil)
            let outcome = try await PilotIngestionService(politicians: StubSource(rows: [sell]), funds: nil).ingest(pilot: pilot, now: now, on: app.db)
            #expect(outcome == .unchanged)
            #expect(try await PilotBookVersion.query(on: app.db).filter(\.$pilotId == pilot.requireID()).count() == 0)
            #expect(try await PilotDisclosureRecord.query(on: app.db).filter(\.$pilotId == pilot.requireID()).count() == 1)
            let reloaded = try #require(try await Pilot.find(pilot.requireID(), on: app.db))
            #expect(reloaded.lastIngestedAt == now)
        }
    }

    @Test("a failure mid-ingest rolls back every stored row")
    func rollsBack() async throws {
        try await withApp { app in
            let pilot = try await makePilot(on: app.db)
            // A NUL byte is rejected by Postgres TEXT, so the second insert fails after the first succeeded.
            let rows = [buy("a", "AAPL", 1000), buy("b", "BAD\u{0}SYM", 1000)]
            await #expect(throws: (any Error).self) {
                _ = try await PilotIngestionService(politicians: StubSource(rows: rows), funds: nil).ingest(pilot: pilot, now: now, on: app.db)
            }
            #expect(try await PilotDisclosureRecord.query(on: app.db).filter(\.$pilotId == pilot.requireID()).count() == 0)
            let reloaded = try #require(try await Pilot.find(pilot.requireID(), on: app.db))
            #expect(reloaded.lastIngestedAt == nil)
        }
    }
}
