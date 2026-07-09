import Foundation
import Redis
import RediStack
import StockPlanShared
import Vapor

/// Macro/inflation domain service. Read path for every endpoint is
/// Redis cache → latest DB snapshot (re-warming the cache) → live provider
/// fetch (persisted on success) → legacy stub data when
/// `MACRO_ALLOW_STUB_FALLBACK` is on (responses marked `source: "stub"`).
protocol MacroService: Sendable {
    var isEnabled: Bool { get }
    func currentInflation(country: MacroCountry, on req: Request) async throws -> InflationSnapshotResponse
    func series(country: MacroCountry, rawSeries: String?, from: String?, to: String?, limit: Int, on req: Request) async throws -> MacroSeriesResponse
    func fedWatch(on req: Request) async throws -> FedWatchResponse
    func items(country: MacroCountry, on req: Request) async throws -> MacroItemsResponse
    func itemSeries(itemID: String, country: MacroCountry, from: String?, to: String?, limit: Int, on req: Request) async throws -> MacroItemSeriesResponse
    func supportedCountries() -> [SupportedCountry]
    /// Live fetch + persist + cache. Called by MacroRefreshJob.
    @discardableResult
    func refresh(country: MacroCountry, on req: Request) async throws -> InflationSnapshotResponse
}

struct DefaultMacroService: MacroService {
    let repository: any MacroRepository
    let registry: MacroProviderRegistry
    let allowStubFallback: Bool

    var isEnabled: Bool {
        !registry.enabledCountries.isEmpty
    }

    // MARK: - Cache keys/TTLs

    private static func snapshotKey(_ country: MacroCountry) -> RedisKey {
        RedisKey("macro:snapshot:v1:\(country.rawValue)")
    }

    private static var fedWatchKey: RedisKey {
        RedisKey("macro:fedwatch:v1")
    }

    private static func snapshotTTL(_ country: MacroCountry) -> Int64 {
        country == .us ? 21600 : 86400 // 6h US (daily-ish gauge), 24h intl (monthly prints)
    }

    private static let fedWatchTTL: Int64 = 3600

    // MARK: - Current snapshot

    func currentInflation(country: MacroCountry, on req: Request) async throws -> InflationSnapshotResponse {
        if let cached: InflationSnapshotResponse = await cacheGet(Self.snapshotKey(country), on: req) {
            return cached
        }
        if let record = try? await repository.latestSnapshot(country: country.rawValue, on: req.db),
           let snapshot = try? JSONDecoder().decode(InflationSnapshotResponse.self, from: Data(record.payload.utf8))
        {
            await cacheSet(Self.snapshotKey(country), value: snapshot, ttl: Self.snapshotTTL(country), on: req)
            return snapshot
        }
        if registry.isEnabled(country) {
            if let snapshot = try? await refresh(country: country, on: req) {
                return snapshot
            }
        }
        guard allowStubFallback else {
            throw Abort(.serviceUnavailable, reason: "No macro data available for \(country.rawValue). Configure providers or enable MACRO_ALLOW_STUB_FALLBACK.")
        }
        return MacroStubData.snapshot(country: country)
    }

    @discardableResult
    func refresh(country: MacroCountry, on req: Request) async throws -> InflationSnapshotResponse {
        let result = try await registry.fetch(country: country, on: req)
        let payloadData = try JSONEncoder().encode(result.snapshot)
        let record = MacroSnapshotRecord(
            country: country.rawValue,
            asOf: result.snapshot.asOf,
            source: result.snapshot.source,
            payload: String(decoding: payloadData, as: UTF8.self),
            fetchedAt: Date()
        )
        try await repository.insertSnapshotIfNew(record, on: req.db)
        let inserted = try await repository.insertPointsIfChanged(result.points, on: req.db)
        req.logger.info("macro_refresh country=\(country.rawValue) points_inserted=\(inserted) as_of=\(result.snapshot.asOf)")
        await cacheSet(Self.snapshotKey(country), value: result.snapshot, ttl: Self.snapshotTTL(country), on: req)
        return result.snapshot
    }

    // MARK: - Series

    func series(country: MacroCountry, rawSeries: String?, from: String?, to: String?, limit: Int, on req: Request) async throws -> MacroSeriesResponse {
        let seriesKey = MacroSeriesKey.resolve(rawSeries)
        let cappedLimit = min(max(limit, 1), 1000)
        let rows = try await repository.series(
            country: country.rawValue,
            seriesKey: seriesKey,
            from: from,
            to: to,
            limit: cappedLimit,
            on: req.db
        )
        if rows.isEmpty, allowStubFallback {
            return MacroStubData.series(country: country, seriesKey: seriesKey)
        }
        return MacroSeriesResponse(
            series: seriesKey,
            points: rows.map { MacroSeriesPoint(date: $0.periodDate, value: $0.value, series: seriesKey) },
            country: country.rawValue,
            unit: rows.first?.unit
        )
    }

    // MARK: - Fed Watch

    func fedWatch(on req: Request) async throws -> FedWatchResponse {
        if let cached: FedWatchResponse = await cacheGet(Self.fedWatchKey, on: req) {
            return cached
        }
        if let response = try await buildFedWatch(on: req) {
            await cacheSet(Self.fedWatchKey, value: response, ttl: Self.fedWatchTTL, on: req)
            return response
        }
        guard allowStubFallback else {
            throw Abort(.serviceUnavailable, reason: "No US macro data ingested yet; fed-watch is unavailable.")
        }
        return MacroStubData.fedWatch()
    }

    private func buildFedWatch(on req: Request) async throws -> FedWatchResponse? {
        func indicator(_ key: MacroSeriesKey, name: String) async throws -> MacroIndicatorDTO? {
            let rows = try await repository.series(
                country: MacroCountry.us.rawValue,
                seriesKey: key.rawValue,
                from: nil,
                to: nil,
                limit: 2,
                on: req.db
            )
            guard let latest = rows.last else { return nil }
            let previous = rows.count >= 2 ? rows[rows.count - 2] : nil
            return MacroIndicatorDTO(
                name: name,
                value: latest.value,
                asOf: latest.periodDate,
                previousValue: previous?.value,
                changeFromPrevious: previous.map { ((latest.value - $0.value) * 100).rounded() / 100 },
                source: "FRED:\(key.rawValue)"
            )
        }

        guard let corePCE = try await indicator(.corePCE, name: "Core PCE") else { return nil }
        let trimmedMean = try await indicator(.trimmedMeanCPI, name: "Trimmed Mean CPI")
        let treasury2Y = try await indicator(.treasury2Y, name: "2Y Treasury")
        let treasury10Y = try await indicator(.treasury10Y, name: "10Y Treasury")
        let real10Y = try await indicator(.real10Y, name: "Real 10Y (TIPS)")
        let breakeven10Y = try await indicator(.breakeven10Y, name: "10Y Breakeven")

        return Self.assembleFedWatch(
            corePCE: corePCE,
            trimmedMean: trimmedMean,
            treasury2Y: treasury2Y,
            treasury10Y: treasury10Y,
            real10Y: real10Y,
            breakeven10Y: breakeven10Y,
            now: Date()
        )
    }

    /// Pure assembly — unit-testable.
    static func assembleFedWatch(
        corePCE: MacroIndicatorDTO,
        trimmedMean: MacroIndicatorDTO?,
        treasury2Y: MacroIndicatorDTO?,
        treasury10Y: MacroIndicatorDTO?,
        real10Y: MacroIndicatorDTO?,
        breakeven10Y: MacroIndicatorDTO?,
        now: Date
    ) -> FedWatchResponse {
        let fedTarget = 2.0
        let distance = ((corePCE.value - fedTarget) * 100).rounded() / 100
        var spread: Double?
        if let twoYear = treasury2Y, let tenYear = treasury10Y {
            spread = ((tenYear.value - twoYear.value) * 100).rounded() / 100
        }
        // Stance heuristic: positive real yields while inflation sits above
        // target reads restrictive; negative real yields read accommodative.
        var stance: String?
        if let realYield = real10Y?.value {
            if realYield >= 0.75 {
                stance = "restrictive"
            } else if realYield <= 0 {
                stance = "accommodative"
            } else {
                stance = "neutral"
            }
        }
        return FedWatchResponse(
            asOf: corePCE.asOf,
            updatedAt: ISO8601DateFormatter().string(from: now),
            source: "FRED (BEA/Cleveland Fed/US Treasury)",
            corePCE: corePCE,
            fedTarget: fedTarget,
            distanceToTarget: distance,
            trimmedMeanCPI: trimmedMean,
            treasury2Y: treasury2Y,
            treasury10Y: treasury10Y,
            spread10Y2Y: spread,
            real10Y: real10Y,
            breakeven10Y: breakeven10Y,
            nextFOMC: FOMCCalendar.nextMeeting(after: now),
            stance: stance
        )
    }

    // MARK: - Items

    func items(country: MacroCountry, on req: Request) async throws -> MacroItemsResponse {
        var items: [MacroItemDTO] = []
        for item in MacroItemsCatalog.items(for: country) {
            let rows = try await repository.series(
                country: country.rawValue,
                seriesKey: MacroSeriesKey.itemKey(item.id),
                from: nil,
                to: nil,
                limit: 14,
                on: req.db
            )
            items.append(Self.itemDTO(item: item, country: country, rows: rows, sourceName: sourceName(for: country)))
        }
        if items.allSatisfy({ $0.asOf == nil }), allowStubFallback {
            return MacroStubData.items(country: country)
        }
        return MacroItemsResponse(
            country: country.rawValue,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            items: items
        )
    }

    /// Pure mapping — unit-testable. For price series (US APU data) YoY/MoM
    /// are computed from the price level; for index/rate series the stored
    /// value *is* the YoY rate.
    static func itemDTO(
        item: MacroItemsCatalog.Item,
        country: MacroCountry,
        rows: [MacroSeriesPointRecord],
        sourceName: String
    ) -> MacroItemDTO {
        guard let latest = rows.last else {
            return MacroItemDTO(
                id: item.id,
                name: item.name,
                emoji: item.emoji,
                country: country.rawValue,
                currency: country.currency,
                unit: item.unit,
                source: sourceName,
                hasSeries: false
            )
        }
        var latestPrice: Double?
        var changeYoY: Double?
        var changeMoM: Double?
        if item.isPrice {
            latestPrice = latest.value
            if rows.count >= 2 {
                let previous = rows[rows.count - 2].value
                if previous != 0 {
                    changeMoM = (((latest.value / previous) - 1) * 10000).rounded() / 100
                }
            }
            if rows.count >= 13 {
                let yearAgo = rows[rows.count - 13].value
                if yearAgo != 0 {
                    changeYoY = (((latest.value / yearAgo) - 1) * 10000).rounded() / 100
                }
            }
        } else {
            changeYoY = latest.value
        }
        return MacroItemDTO(
            id: item.id,
            name: item.name,
            emoji: item.emoji,
            country: country.rawValue,
            currency: country.currency,
            unit: item.unit,
            latestPrice: latestPrice,
            changeYoY: changeYoY,
            changeMoM: changeMoM,
            asOf: latest.periodDate,
            source: sourceName,
            hasSeries: true
        )
    }

    func itemSeries(itemID: String, country: MacroCountry, from: String?, to: String?, limit: Int, on req: Request) async throws -> MacroItemSeriesResponse {
        guard let item = MacroItemsCatalog.item(id: itemID, country: country) else {
            throw Abort(.notFound, reason: "Unknown item '\(itemID)' for \(country.rawValue). See /v1/macro/items.")
        }
        let cappedLimit = min(max(limit, 1), 1000)
        let key = MacroSeriesKey.itemKey(item.id)
        let rows = try await repository.series(
            country: country.rawValue,
            seriesKey: key,
            from: from,
            to: to,
            limit: cappedLimit,
            on: req.db
        )
        return MacroItemSeriesResponse(
            itemId: item.id,
            country: country.rawValue,
            currency: country.currency,
            unit: item.unit,
            points: rows.map { MacroSeriesPoint(date: $0.periodDate, value: $0.value, series: key) }
        )
    }

    // MARK: - Supported countries

    func supportedCountries() -> [SupportedCountry] {
        MacroCountry.allCases.map { country in
            SupportedCountry(
                code: country.rawValue,
                name: country.displayName,
                currency: country.currency,
                dataSource: sourceName(for: country),
                hasDailyData: country == .us && registry.isEnabled(.us)
            )
        }
    }

    private func sourceName(for country: MacroCountry) -> String {
        guard let entry = registry.providers(for: country), registry.isEnabled(country) else {
            return allowStubFallback ? "stub" : "disabled"
        }
        var parts = [entry.primary.name]
        parts += entry.enrichments.filter(\.isEnabled).map(\.name)
        return parts.joined(separator: " + ")
    }

    // MARK: - Redis helpers (best-effort; cache errors never fail a request)

    private func cacheGet<Value: Decodable>(_ key: RedisKey, on req: Request) async -> Value? {
        guard req.application.redis.configuration != nil else { return nil }
        guard let raw = try? await req.redis.get(key, as: String.self).get() else { return nil }
        return try? JSONDecoder().decode(Value.self, from: Data(raw.utf8))
    }

    private func cacheSet(_ key: RedisKey, value: some Encodable, ttl: Int64, on req: Request) async {
        guard req.application.redis.configuration != nil else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        _ = try? await req.redis.setex(key, to: String(decoding: data, as: UTF8.self), expirationInSeconds: Int(ttl)).get()
    }
}
