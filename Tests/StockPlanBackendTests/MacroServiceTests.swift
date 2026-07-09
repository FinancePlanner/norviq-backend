import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

/// Canned provider used to drive the service/registry/job without network.
private struct StubMacroProvider: MacroProvider {
    let name: String
    var failing = false
    var snapshotAsOf = "2026-06-01"
    var headlineValue = 3.3

    func supports(_: MacroCountry) -> Bool {
        true
    }

    func fetchSnapshot(country: MacroCountry, on _: Request) async throws -> MacroProviderResult {
        if failing {
            throw Abort(.badGateway, reason: "stub provider forced failure")
        }
        let headline = InflationGaugeDTO(
            name: "Stub Headline",
            nowValue: headlineValue,
            officialValue: headlineValue,
            officialAsOf: String(snapshotAsOf.prefix(7))
        )
        let snapshot = InflationSnapshotResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: snapshotAsOf,
            updatedAt: "now",
            source: name,
            headline: headline,
            gauges: [headline],
            components: [],
            topMovers: []
        )
        let points = [
            MacroSeriesPointRecord(
                country: country.rawValue,
                seriesKey: MacroSeriesKey.headlineCPI.rawValue,
                periodDate: snapshotAsOf,
                value: headlineValue,
                unit: "percent",
                source: name,
                vintageDate: Date()
            ),
        ]
        return MacroProviderResult(snapshot: snapshot, points: points)
    }
}

@Suite("MacroService Tests", .serialized)
struct MacroServiceTests {
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

    private func registry(
        primary: any MacroProvider,
        fallback: (any MacroProvider)? = nil,
        countries: [MacroCountry] = MacroCountry.allCases
    ) -> MacroProviderRegistry {
        var providers: [MacroCountry: MacroProviderRegistry.CountryProviders] = [:]
        for country in countries {
            providers[country] = .init(primary: primary, fallback: fallback, enrichments: [])
        }
        return MacroProviderRegistry(providers: providers)
    }

    private func request(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    @Test("live fetch persists snapshot + points and serves subsequent reads from DB")
    func liveFetchPersists() async throws {
        try await withApp { app in
            let repo = DatabaseMacroRepository()
            let service = DefaultMacroService(
                repository: repo,
                registry: registry(primary: StubMacroProvider(name: "stub-live")),
                allowStubFallback: false
            )
            let first = try await service.currentInflation(country: .us, on: request(app))
            #expect(first.source == "stub-live")

            let stored = try await repo.latestSnapshot(country: "US", on: app.db)
            #expect(stored != nil)
            let points = try await repo.series(country: "US", seriesKey: "headline_cpi", from: nil, to: nil, limit: 10, on: app.db)
            #expect(points.count == 1)

            // Second read comes from the DB path (no cache in .testing).
            let second = try await service.currentInflation(country: .us, on: request(app))
            #expect(second == first)
        }
    }

    @Test("primary provider failure falls back to the fallback provider")
    func fallbackProvider() async throws {
        try await withApp { app in
            let failing = StubMacroProvider(name: "primary-down", failing: true)
            let fallback = StubMacroProvider(name: "fallback-up", headlineValue: 4.5)
            let service = DefaultMacroService(
                repository: DatabaseMacroRepository(),
                registry: registry(primary: failing, fallback: fallback),
                allowStubFallback: false
            )
            let snapshot = try await service.currentInflation(country: .br, on: request(app))
            #expect(snapshot.source == "fallback-up")
            #expect(snapshot.headline.nowValue == 4.5)
        }
    }

    @Test("no data + stub fallback disabled → 503; enabled → stub-marked response")
    func stubFallbackFlag() async throws {
        try await withApp { app in
            let disabledRegistry = MacroProviderRegistry(providers: [:])
            let strict = DefaultMacroService(
                repository: DatabaseMacroRepository(),
                registry: disabledRegistry,
                allowStubFallback: false
            )
            await #expect(throws: Abort.self) {
                _ = try await strict.currentInflation(country: .us, on: self.request(app))
            }

            let lenient = DefaultMacroService(
                repository: DatabaseMacroRepository(),
                registry: disabledRegistry,
                allowStubFallback: true
            )
            let snapshot = try await lenient.currentInflation(country: .us, on: request(app))
            #expect(snapshot.source == "stub")
            let fedWatch = try await lenient.fedWatch(on: request(app))
            #expect(fedWatch.source == "stub")
            let items = try await lenient.items(country: .us, on: request(app))
            #expect(items.items.allSatisfy { $0.source == "stub" })
        }
    }

    @Test("fed-watch assembles spread, distance-to-target, and stance from stored US points")
    func fedWatchFromPoints() async throws {
        try await withApp { app in
            let repo = DatabaseMacroRepository()
            let vintage = Date()
            func usPoint(_ key: MacroSeriesKey, _ period: String, _ value: Double) -> MacroSeriesPointRecord {
                MacroSeriesPointRecord(country: "US", seriesKey: key.rawValue, periodDate: period, value: value, unit: "percent", source: "fred", vintageDate: vintage)
            }
            _ = try await repo.insertPointsIfChanged([
                usPoint(.corePCE, "2026-04-01", 3.38),
                usPoint(.corePCE, "2026-05-01", 3.41),
                usPoint(.treasury2Y, "2026-07-07", 4.19),
                usPoint(.treasury10Y, "2026-07-07", 4.55),
                usPoint(.real10Y, "2026-07-07", 0.48),
            ], on: app.db)

            let service = DefaultMacroService(
                repository: repo,
                registry: registry(primary: StubMacroProvider(name: "unused")),
                allowStubFallback: false
            )
            let fedWatch = try await service.fedWatch(on: request(app))
            #expect(fedWatch.corePCE.value == 3.41)
            #expect(fedWatch.corePCE.changeFromPrevious == 0.03)
            #expect(fedWatch.distanceToTarget == 1.41)
            #expect(fedWatch.spread10Y2Y == 0.36)
            #expect(fedWatch.stance == "neutral")
            #expect(fedWatch.nextFOMC != nil)
        }
    }

    @Test("item metrics computed from price series; unknown item 404s")
    func itemMapping() async throws {
        try await withApp { app in
            let repo = DatabaseMacroRepository()
            let vintage = Date()
            // 13 months of egg prices ending 2026-06: +10% YoY, +2% MoM.
            var points: [MacroSeriesPointRecord] = []
            let prices: [Double] = [3.00, 3.02, 3.03, 3.05, 3.08, 3.10, 3.12, 3.15, 3.18, 3.20, 3.22, 3.235, 3.30]
            for (index, price) in prices.enumerated() {
                let month = index < 7 ? index + 6 : index - 6 // 2025-06 ... 2026-06
                let year = index < 7 ? 2025 : 2026
                points.append(
                    MacroSeriesPointRecord(
                        country: "US",
                        seriesKey: MacroSeriesKey.itemKey("eggs"),
                        periodDate: String(format: "%d-%02d-01", year, month),
                        value: price,
                        unit: "USD per dozen",
                        source: "fred",
                        vintageDate: vintage
                    )
                )
            }
            _ = try await repo.insertPointsIfChanged(points, on: app.db)

            let service = DefaultMacroService(
                repository: repo,
                registry: registry(primary: StubMacroProvider(name: "unused")),
                allowStubFallback: false
            )
            let items = try await service.items(country: .us, on: request(app))
            let eggs = try #require(items.items.first { $0.id == "eggs" })
            #expect(eggs.latestPrice == 3.30)
            #expect(eggs.changeYoY == 10.0)
            #expect(eggs.changeMoM == 2.01)
            #expect(eggs.hasSeries)

            let series = try await service.itemSeries(itemID: "eggs", country: .us, from: nil, to: nil, limit: 100, on: request(app))
            #expect(series.points.count == 13)
            #expect(series.unit == "USD per dozen")

            await #expect(throws: Abort.self) {
                _ = try await service.itemSeries(itemID: "unknown", country: .us, from: nil, to: nil, limit: 10, on: self.request(app))
            }
        }
    }

    @Test("refresh job runOnce persists per enabled country and isolates failures")
    func refreshJobRunOnce() async throws {
        try await withApp { app in
            let repo = DatabaseMacroRepository()
            var providers: [MacroCountry: MacroProviderRegistry.CountryProviders] = [:]
            providers[.us] = .init(primary: StubMacroProvider(name: "us-ok"), fallback: nil, enrichments: [])
            providers[.br] = .init(primary: StubMacroProvider(name: "br-down", failing: true), fallback: nil, enrichments: [])
            let registry = MacroProviderRegistry(providers: providers)
            app.macroRepository = repo
            app.macroProviderRegistry = registry
            app.macroSyncStatus = MacroSyncStatus()
            app.macroService = DefaultMacroService(repository: repo, registry: registry, allowStubFallback: false)

            let job = MacroRefreshJob(tickIntervalSeconds: 3600, usRefreshSeconds: 21600, intlRefreshSeconds: 86400)
            await job.runOnce(app, force: true)

            // US succeeded, BR failure did not block it.
            #expect(app.macroSyncStatus.lastSuccessAt(.us) != nil)
            #expect(app.macroSyncStatus.lastSuccessAt(.br) == nil)
            let usSnapshot = try await repo.latestSnapshot(country: "US", on: app.db)
            #expect(usSnapshot != nil)
            let brSnapshot = try await repo.latestSnapshot(country: "BR", on: app.db)
            #expect(brSnapshot == nil)

            // Within cadence → non-forced tick skips the refresh (no new snapshot rows).
            let before = try await MacroSnapshotRecord.query(on: app.db).count()
            await job.runOnce(app)
            let after = try await MacroSnapshotRecord.query(on: app.db).count()
            #expect(before == after)
        }
    }
}
