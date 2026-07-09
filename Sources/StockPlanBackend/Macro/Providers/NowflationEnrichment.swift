import Foundation
import StockPlanShared
import Vapor

/// Nowflation.com enrichment for the US snapshot: layers the daily
/// market-derived gauge (nowValue, COL variant, cumulative-since-base, gap,
/// narrative, next-print forecast) on top of the official FRED numbers.
///
/// nowflation.com is a JS-rendered SPA whose open-data JSON endpoints are not
/// statically discoverable, so both the base URL and the snapshot path come
/// from env (`NOWFLATION_BASE_URL`, `NOWFLATION_SNAPSHOT_PATH`) and the
/// payload is decoded tolerantly: any missing/renamed field degrades to nil
/// instead of failing. Enrichment NEVER fails the refresh — on any error the
/// original FRED-only result is returned unchanged.
struct NowflationEnrichment: MacroEnrichmentProviding {
    let name = "nowflation"
    let baseURL: String
    let snapshotPath: String

    var isEnabled: Bool {
        !baseURL.isEmpty && !snapshotPath.isEmpty
    }

    func enrich(_ result: MacroProviderResult, country: MacroCountry, on req: Request) async -> MacroProviderResult {
        guard isEnabled, country == .us else { return result }
        do {
            let payload = try await fetchPayload(on: req)
            return Self.apply(payload: payload, to: result, providerName: name, now: Date())
        } catch {
            req.logger.warning("nowflation_enrichment failed, serving official-only snapshot error=\(String(describing: error))")
            return result
        }
    }

    /// Pure merge — unit-testable.
    static func apply(
        payload: NowflationPayload,
        to result: MacroProviderResult,
        providerName: String,
        now: Date
    ) -> MacroProviderResult {
        guard let nowValue = payload.gaugeYoY else { return result }
        var merged = result
        let official = result.snapshot.headline.officialValue
        let headline = InflationGaugeDTO(
            name: "Nowflation CPI",
            nowValue: nowValue,
            officialValue: official,
            officialAsOf: result.snapshot.headline.officialAsOf,
            gap: official.map { ((nowValue - $0) * 100).rounded() / 100 },
            colVariant: payload.colYoY,
            cumulativeSinceBase: payload.cumulativeSinceBase,
            basePeriod: payload.basePeriod ?? "2018-01"
        )

        var gauges = result.snapshot.gauges
        if let index = gauges.firstIndex(where: { $0.name == result.snapshot.headline.name }) {
            gauges[index] = headline
        } else {
            gauges.insert(headline, at: 0)
        }

        var nextPrint = result.snapshot.nextPrintCountdown
        if let forecast = payload.forecast {
            nextPrint = NextPrintDTO(
                date: nextPrint?.date,
                daysRemaining: nextPrint?.daysRemaining,
                forecastNowflation: forecast,
                streetConsensus: payload.streetConsensus ?? nextPrint?.streetConsensus,
                lastOfficial: nextPrint?.lastOfficial
            )
        }

        merged.snapshot = InflationSnapshotResponse(
            country: result.snapshot.country,
            currency: result.snapshot.currency,
            asOf: payload.asOf ?? result.snapshot.asOf,
            updatedAt: result.snapshot.updatedAt,
            source: "nowflation.com + " + result.snapshot.source,
            headline: headline,
            gauges: gauges,
            components: result.snapshot.components,
            topMovers: result.snapshot.topMovers,
            notes: payload.notes ?? result.snapshot.notes,
            nextPrintCountdown: nextPrint
        )
        let gaugePeriod = payload.asOf ?? (merged.snapshot.asOf.isEmpty ? nil : merged.snapshot.asOf)
        if let asOf = gaugePeriod {
            merged.points.append(
                MacroSeriesPointRecord(
                    country: MacroCountry.us.rawValue,
                    seriesKey: MacroSeriesKey.nowflationGauge.rawValue,
                    periodDate: asOf,
                    value: nowValue,
                    unit: "percent",
                    source: providerName,
                    vintageDate: now
                )
            )
        }
        return merged
    }

    private func fetchPayload(on req: Request) async throws -> NowflationPayload {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = snapshotPath.hasPrefix("/") ? snapshotPath : "/" + snapshotPath
        let response = try await req.client.get(URI(string: trimmed + path)) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(15)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Nowflation request failed with status \(response.status.code).")
        }
        var body = response.body ?? ByteBuffer()
        guard let data = body.readData(length: body.readableBytes) else {
            throw Abort(.badGateway, reason: "Empty Nowflation response body.")
        }
        return try NowflationPayload.decode(from: data)
    }
}

/// Tolerantly-decoded Nowflation snapshot. The upstream schema is not under
/// our control; each field is resolved from a list of candidate keys over a
/// loose JSON tree, so shape drift degrades fields to nil.
struct NowflationPayload: Equatable {
    var gaugeYoY: Double?
    var colYoY: Double?
    var cumulativeSinceBase: Double?
    var basePeriod: String?
    var asOf: String?
    var notes: String?
    var forecast: Double?
    var streetConsensus: Double?

    static func decode(from data: Data) throws -> NowflationPayload {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw Abort(.badGateway, reason: "Nowflation payload is not a JSON object.")
        }
        var payload = NowflationPayload()
        payload.gaugeYoY = double(in: root, candidates: ["gaugeYoY", "nowflation_yoy", "nowflationYoY", "gauge.yoy", "headline.now", "yoy"])
        payload.colYoY = double(in: root, candidates: ["colYoY", "col_yoy", "costOfLivingYoY", "col.yoy"])
        payload.cumulativeSinceBase = double(in: root, candidates: ["cumulativeSinceBase", "cumulative_since_base", "cumulative"])
        payload.basePeriod = string(in: root, candidates: ["basePeriod", "base_period"])
        payload.asOf = string(in: root, candidates: ["asOf", "as_of", "date", "published"])
        payload.notes = string(in: root, candidates: ["notes", "narrative", "summary"])
        payload.forecast = double(in: root, candidates: ["forecast", "cpiForecast", "forecast.nowflation"])
        payload.streetConsensus = double(in: root, candidates: ["streetConsensus", "street_consensus", "street"])
        return payload
    }

    /// Resolves dotted key paths over nested dictionaries.
    private static func lookup(in root: [String: Any], path: String) -> Any? {
        var current: Any = root
        for part in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(part)] else { return nil }
            current = next
        }
        return current
    }

    private static func double(in root: [String: Any], candidates: [String]) -> Double? {
        for candidate in candidates {
            if let raw = lookup(in: root, path: candidate) {
                if let value = raw as? Double {
                    return value
                }
                if let value = raw as? Int {
                    return Double(value)
                }
                if let value = raw as? String, let parsed = Double(value) {
                    return parsed
                }
            }
        }
        return nil
    }

    private static func string(in root: [String: Any], candidates: [String]) -> String? {
        for candidate in candidates {
            if let value = lookup(in: root, path: candidate) as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
