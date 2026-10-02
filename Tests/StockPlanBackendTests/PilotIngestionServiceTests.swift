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
        }
    }

    @Test("a new disclosure writes the next version")
    func newVersion() async throws {
        try await withApp { app in
            let pilot = try await makePilot(on: app.db)
            _ = try await PilotIngestionService(politicians: StubSource(rows: [buy("a", "AAPL", 1000)]), funds: nil).ingest(pilot: pilot, now: now, on: app.db)
            let outcome = try await PilotIngestionService(politicians: StubSource(rows: [buy("a", "AAPL", 1000), buy("c", "KO", 1000)]), funds: nil).ingest(pilot: pilot, now: now, on: app.db)
            #expect(outcome == .newVersion(2))
        }
    }
}
