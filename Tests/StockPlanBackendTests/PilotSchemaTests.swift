import Fluent
import Foundation
import SQLKit
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Pilot schema", .serialized)
struct PilotSchemaTests {
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

    @Test("a disclosure source_key is unique per pilot")
    func disclosureUnique() async throws {
        try await withApp { app in
            let pilot = Pilot(kind: .politician, slug: "test-\(UUID().uuidString.prefix(6))", displayName: "Test", chamber: "house", nameAliases: ["Test Person"])
            try await pilot.create(on: app.db)
            let first = try PilotDisclosureRecord(pilotId: pilot.requireID(), sourceKey: "k1", symbol: "AAPL", side: .buy, instrument: .stock)
            try await first.create(on: app.db)
            let dupe = try PilotDisclosureRecord(pilotId: pilot.requireID(), sourceKey: "k1", symbol: "AAPL", side: .buy, instrument: .stock)
            await #expect(throws: (any Error).self) { try await dupe.create(on: app.db) }
        }
    }

    @Test("book weights round-trip as JSON")
    func bookWeights() async throws {
        try await withApp { app in
            let pilot = Pilot(kind: .fund, slug: "fund-\(UUID().uuidString.prefix(6))", displayName: "Fund", cik: "0000000001")
            try await pilot.create(on: app.db)
            let version = try PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: Date(), weights: ["AAPL": 0.6, "KO": 0.4], skippedPuts: 2)
            try await version.create(on: app.db)
            let loaded = try #require(try await PilotBookVersion.find(version.requireID(), on: app.db))
            #expect(loaded.weights == ["AAPL": 0.6, "KO": 0.4])
            #expect(loaded.skippedPuts == 2)
        }
    }
}
