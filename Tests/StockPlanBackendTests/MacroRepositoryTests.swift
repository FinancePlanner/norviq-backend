import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("MacroRepository Tests", .serialized)
struct MacroRepositoryTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
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

    private func point(
        period: String,
        value: Double,
        vintage: Date,
        seriesKey: String = "headline_cpi",
        country: String = "US"
    ) -> MacroSeriesPointRecord {
        MacroSeriesPointRecord(
            country: country,
            seriesKey: seriesKey,
            periodDate: period,
            value: value,
            unit: "percent",
            source: "fred",
            vintageDate: vintage
        )
    }

    @Test("vintage safety: unchanged values are not duplicated, revisions append")
    func vintageSafety() async throws {
        try await withApp { app in
            let repo = DatabaseMacroRepository()
            let db = app.db
            let vintage1 = Date(timeIntervalSince1970: 1_783_000_000)
            let vintage2 = vintage1.addingTimeInterval(86400)

            let first = try await repo.insertPointsIfChanged(
                [point(period: "2026-05-01", value: 4.2, vintage: vintage1), point(period: "2026-06-01", value: 4.1, vintage: vintage1)],
                on: db
            )
            #expect(first == 2)

            // Same values again → nothing inserted.
            let second = try await repo.insertPointsIfChanged(
                [point(period: "2026-05-01", value: 4.2, vintage: vintage2), point(period: "2026-06-01", value: 4.1, vintage: vintage2)],
                on: db
            )
            #expect(second == 0)

            // Revised value → new vintage row appended, old row preserved.
            let third = try await repo.insertPointsIfChanged(
                [point(period: "2026-05-01", value: 4.3, vintage: vintage2)],
                on: db
            )
            #expect(third == 1)
            let allRows = try await MacroSeriesPointRecord.query(on: db).all()
            #expect(allRows.count == 3)

            // Reads resolve to the latest vintage per period.
            let series = try await repo.series(country: "US", seriesKey: "headline_cpi", from: nil, to: nil, limit: 100, on: db)
            #expect(series.map(\.periodDate) == ["2026-05-01", "2026-06-01"])
            #expect(series.map(\.value) == [4.3, 4.1])
        }
    }

    @Test("series respects range filters and limit keeps most recent periods")
    func seriesFilters() async throws {
        try await withApp { app in
            let repo = DatabaseMacroRepository()
            let db = app.db
            let vintage = Date()
            let points = (1 ... 6).map { month in
                point(period: String(format: "2026-%02d-01", month), value: Double(month), vintage: vintage)
            }
            _ = try await repo.insertPointsIfChanged(points, on: db)

            let ranged = try await repo.series(country: "US", seriesKey: "headline_cpi", from: "2026-02-01", to: "2026-04-01", limit: 100, on: db)
            #expect(ranged.map(\.periodDate) == ["2026-02-01", "2026-03-01", "2026-04-01"])

            let limited = try await repo.series(country: "US", seriesKey: "headline_cpi", from: nil, to: nil, limit: 2, on: db)
            #expect(limited.map(\.periodDate) == ["2026-05-01", "2026-06-01"])

            let latest = try await repo.latestPoint(country: "US", seriesKey: "headline_cpi", on: db)
            #expect(latest?.periodDate == "2026-06-01")
        }
    }

    @Test("snapshots are insert-only with per-(country, asOf, source) dedupe and freshness reads back")
    func snapshotDedupe() async throws {
        try await withApp { app in
            let repo = DatabaseMacroRepository()
            let db = app.db
            let snapshot = MacroSnapshotRecord(country: "US", asOf: "2026-07-01", source: "fred", payload: "{}", fetchedAt: Date())
            let inserted = try await repo.insertSnapshotIfNew(snapshot, on: db)
            #expect(inserted)
            let duplicate = MacroSnapshotRecord(country: "US", asOf: "2026-07-01", source: "fred", payload: "{}", fetchedAt: Date())
            let insertedAgain = try await repo.insertSnapshotIfNew(duplicate, on: db)
            #expect(!insertedAgain)

            let newer = MacroSnapshotRecord(country: "US", asOf: "2026-08-01", source: "fred", payload: "{\"v\":2}", fetchedAt: Date().addingTimeInterval(60))
            _ = try await repo.insertSnapshotIfNew(newer, on: db)
            let latest = try await repo.latestSnapshot(country: "US", on: db)
            #expect(latest?.asOf == "2026-08-01")

            let freshness = try await repo.freshness(on: db)
            #expect(freshness["US"] != nil)
        }
    }
}
