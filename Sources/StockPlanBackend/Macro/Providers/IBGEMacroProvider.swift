import Foundation
import StockPlanShared
import Vapor

/// IBGE SIDRA provider for Brazil (IPCA). No API key.
///
/// Quirks handled here:
/// - Every response is an array of string-keyed rows whose FIRST element is a
///   header row (labels, not data) — always skipped.
/// - All values are strings ("4.52"); missing values are "..." or "-".
/// - Period codes are "yyyyMM" (D3C on table 1737, D2C on table 7060).
struct IBGEMacroProvider: MacroProvider {
    let name = "ibge"
    var baseURL: String = "https://apisidra.ibge.gov.br"

    /// IPCA groups on table 7060 (classification c315). Codes pinned from
    /// SIDRA; covered by fixture tests.
    static let groups: [(code: String, label: String)] = [
        ("7170", "Alimentação e bebidas"),
        ("7445", "Habitação"),
        ("7486", "Artigos de residência"),
        ("7558", "Vestuário"),
        ("7625", "Transportes"),
        ("7660", "Saúde e cuidados pessoais"),
        ("7712", "Despesas pessoais"),
        ("7766", "Educação"),
        ("7786", "Comunicação"),
    ]

    func supports(_ country: MacroCountry) -> Bool {
        country == .br
    }

    func fetchSnapshot(country: MacroCountry, on req: Request) async throws -> MacroProviderResult {
        guard country == .br else {
            throw Abort(.serviceUnavailable, reason: "IBGE provider only supports BR.")
        }

        // Table 1737, variable 2265 = IPCA 12-month accumulated. Last 97
        // months ≈ 8 years of headline history in a single call.
        let headlineRows = try await fetchRows(
            path: "/values/t/1737/n1/all/v/2265/p/last%2097",
            on: req
        )
        let headlineSeries = Self.parseSeries(rows: headlineRows, periodKey: "D3C")
        guard let latestHeadline = headlineSeries.last else {
            throw Abort(.badGateway, reason: "IBGE returned no IPCA observations.")
        }

        // Table 7060: v/63 (MoM) + v/2265 (12-month) for the IPCA groups.
        let groupCodes = Self.groups.map(\.code).joined(separator: ",")
        let groupRows = try await fetchRows(
            path: "/values/t/7060/n1/all/v/63,2265/p/last%201/c315/\(groupCodes)",
            on: req
        )
        let groupReadings = Self.parseGroups(rows: groupRows)

        let now = Date()
        var points: [MacroSeriesPointRecord] = headlineSeries.map {
            MacroSeriesPointRecord(
                country: MacroCountry.br.rawValue,
                seriesKey: MacroSeriesKey.headlineCPI.rawValue,
                periodDate: $0.period,
                value: $0.value,
                unit: "percent",
                source: name,
                vintageDate: now
            )
        }
        for item in MacroItemsCatalog.items(for: .br) {
            guard case let .sidraClassification(code) = item.sourceRef,
                  let reading = groupReadings[code], let yoy = reading.yoy
            else { continue }
            points.append(
                MacroSeriesPointRecord(
                    country: MacroCountry.br.rawValue,
                    seriesKey: MacroSeriesKey.itemKey(item.id),
                    periodDate: latestHeadline.period,
                    value: yoy,
                    unit: item.unit,
                    source: name,
                    vintageDate: now
                )
            )
        }

        let officialAsOf = String(latestHeadline.period.prefix(7))
        let headline = InflationGaugeDTO(
            name: "IPCA (12 meses)",
            nowValue: latestHeadline.value,
            officialValue: latestHeadline.value,
            officialAsOf: officialAsOf
        )

        var components: [InflationComponentDTO] = []
        var moverCandidates: [(mover: TopMoverDTO, magnitude: Double)] = []
        for group in Self.groups {
            guard let reading = groupReadings[group.code], let yoy = reading.yoy else { continue }
            components.append(InflationComponentDTO(category: group.label, ourYoY: yoy, blsYoY: yoy))
            let direction: String = if let mom = reading.mom {
                mom > 0 ? "up" : (mom < 0 ? "down" : "flat")
            } else {
                yoy >= 0 ? "up" : "down"
            }
            moverCandidates.append((
                TopMoverDTO(category: group.label, changeYoY: yoy, changeMoM: reading.mom, direction: direction),
                abs(yoy)
            ))
        }
        let topMovers = moverCandidates.sorted { $0.magnitude > $1.magnitude }.prefix(6).map(\.mover)

        let snapshot = InflationSnapshotResponse(
            country: MacroCountry.br.rawValue,
            currency: MacroCountry.br.currency,
            asOf: latestHeadline.period,
            updatedAt: ISO8601DateFormatter().string(from: now),
            source: "IBGE (IPCA) (\(officialAsOf))",
            headline: headline,
            gauges: [headline],
            components: components,
            topMovers: Array(topMovers),
            notes: "IPCA acumulado em 12 meses (IBGE/SIDRA)."
        )
        return MacroProviderResult(snapshot: snapshot, points: points)
    }

    // MARK: - Parsing (pure, fixture-tested)

    struct SeriesReading: Equatable {
        let period: String // yyyy-MM-01
        let value: Double
    }

    struct GroupReading: Equatable {
        var mom: Double?
        var yoy: Double?
    }

    /// Parses a single-variable SIDRA response into an ascending series.
    static func parseSeries(rows: [[String: String]], periodKey: String) -> [SeriesReading] {
        rows.dropFirst().compactMap { row in
            guard let rawPeriod = row[periodKey],
                  let period = normalizePeriod(rawPeriod),
                  let value = parseValue(row["V"])
            else { return nil }
            return SeriesReading(period: period, value: value)
        }
        .sorted { $0.period < $1.period }
    }

    /// Parses table 7060 rows into per-group MoM (v63) / 12-month (v2265) readings.
    static func parseGroups(rows: [[String: String]]) -> [String: GroupReading] {
        var result: [String: GroupReading] = [:]
        for row in rows.dropFirst() {
            guard let groupCode = row["D4C"], let variableCode = row["D2C"],
                  let value = parseValue(row["V"])
            else { continue }
            var reading = result[groupCode] ?? GroupReading()
            switch variableCode {
            case "63": reading.mom = value
            case "2265": reading.yoy = value
            default: continue
            }
            result[groupCode] = reading
        }
        return result
    }

    /// SIDRA emits "..." / "-" for missing values and uses "." as decimal? No —
    /// values use "." as the decimal separator ("4.52").
    static func parseValue(_ raw: String?) -> Double? {
        guard let raw, raw != "...", raw != "-", raw != ".." else { return nil }
        return Double(raw)
    }

    /// "202606" → "2026-06-01"
    static func normalizePeriod(_ raw: String) -> String? {
        guard raw.count == 6, Int(raw) != nil else { return nil }
        let year = raw.prefix(4)
        let month = raw.suffix(2)
        return "\(year)-\(month)-01"
    }

    // MARK: - HTTP

    private func fetchRows(path: String, on req: Request) async throws -> [[String: String]] {
        let uri = URI(string: baseURL + path + "?formato=json")
        let response = try await req.client.get(uri) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(30)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBGE SIDRA request failed with status \(response.status.code).")
        }
        var body = response.body ?? ByteBuffer()
        guard let data = body.readData(length: body.readableBytes) else {
            throw Abort(.badGateway, reason: "Empty IBGE SIDRA response body.")
        }
        do {
            return try JSONDecoder().decode([[String: String]].self, from: data)
        } catch {
            throw Abort(.badGateway, reason: "Failed to decode IBGE SIDRA response.")
        }
    }
}
