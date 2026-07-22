import Foundation
import StockPlanShared
import Vapor

/// Eurostat HICP provider for the Euro Area and Portugal. No API key.
/// Dataset: prc_hicp_manr (HICP monthly annual rate of change).
/// Response format is JSON-stat 2.0 with a sparse `value` map — decoded by
/// `JSONStatDataset` below.
struct EurostatMacroProvider: MacroProvider {
    let name = "eurostat"
    var baseURL: String = "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data"

    /// COICOP divisions with display names (CP01..CP12).
    static let divisions: [(code: String, label: String)] = [
        ("CP01", "Food and non-alcoholic beverages"),
        ("CP02", "Alcoholic beverages and tobacco"),
        ("CP03", "Clothing and footwear"),
        ("CP04", "Housing, water, electricity, gas"),
        ("CP05", "Furnishings and household equipment"),
        ("CP06", "Health"),
        ("CP07", "Transport"),
        ("CP08", "Communications"),
        ("CP09", "Recreation and culture"),
        ("CP10", "Education"),
        ("CP11", "Restaurants and hotels"),
        ("CP12", "Miscellaneous goods and services"),
    ]

    static let headlineCode = "CP00"
    static let coreCode = "TOT_X_NRG_FOOD"
    static let energyCode = "NRG"
    static let foodCode = "FOOD"

    func supports(_ country: MacroCountry) -> Bool {
        country == .pt || country == .ea
    }

    func fetchSnapshot(country: MacroCountry, on req: Request) async throws -> MacroProviderResult {
        guard supports(country) else {
            throw Abort(.serviceUnavailable, reason: "Eurostat provider does not support \(country.rawValue).")
        }
        let geo = country == .pt ? "PT" : "EA20"
        let sinceTimePeriod = Self.sincePeriod(yearsBack: 8)

        var coicops = [Self.headlineCode, Self.coreCode, Self.energyCode, Self.foodCode]
        coicops += Self.divisions.map(\.code)
        coicops += MacroItemsCatalog.items(for: country).compactMap {
            if case let .eurostatCoicop(code) = $0.sourceRef {
                return code
            }
            return nil
        }

        var query: [(String, String)] = [
            ("format", "JSON"),
            ("unit", "RCH_A"),
            ("geo", geo),
            ("sinceTimePeriod", sinceTimePeriod),
        ]
        query += coicops.map { ("coicop", $0) }

        let dataset = try await fetchDataset(path: "/prc_hicp_manr", query: query, on: req)
        return try Self.buildResult(dataset: dataset, country: country, providerName: name, now: Date())
    }

    /// Pure snapshot assembly from a decoded dataset — unit-testable.
    static func buildResult(
        dataset: JSONStatDataset,
        country: MacroCountry,
        providerName: String,
        now: Date
    ) throws -> MacroProviderResult {
        let periods = dataset.categoryIDs(dimension: "time").sorted()
        guard !periods.isEmpty else {
            throw Abort(.badGateway, reason: "Eurostat returned no time periods.")
        }

        func seriesValues(coicop: String) -> [(period: String, value: Double)] {
            periods.compactMap { period in
                dataset.value(at: ["coicop": coicop, "time": period]).map { (period, $0) }
            }
        }

        var points: [MacroSeriesPointRecord] = []
        func appendPoints(_ values: [(period: String, value: Double)], key: String, unit: String = "percent") {
            points += values.map {
                MacroSeriesPointRecord(
                    country: country.rawValue,
                    seriesKey: key,
                    periodDate: $0.period + "-01",
                    value: $0.value,
                    unit: unit,
                    source: providerName,
                    vintageDate: now
                )
            }
        }

        let headlineValues = seriesValues(coicop: headlineCode)
        guard let latestHeadline = headlineValues.last else {
            throw Abort(.badGateway, reason: "Eurostat returned no headline (CP00) observations for \(country.rawValue).")
        }
        appendPoints(headlineValues, key: MacroSeriesKey.headlineCPI.rawValue)

        let coreValues = seriesValues(coicop: coreCode)
        appendPoints(coreValues, key: MacroSeriesKey.coreCPI.rawValue)
        let energyValues = seriesValues(coicop: energyCode)
        appendPoints(energyValues, key: MacroSeriesKey.energyCPI.rawValue)
        let foodValues = seriesValues(coicop: foodCode)
        appendPoints(foodValues, key: MacroSeriesKey.foodCPI.rawValue)

        // Housing rent proxy (CP04) for lite housing hub.
        let housingValues = seriesValues(coicop: "CP04")
        appendPoints(housingValues, key: MacroSeriesKey.rentYoY.rawValue)

        for item in MacroItemsCatalog.items(for: country) {
            guard case let .eurostatCoicop(code) = item.sourceRef else { continue }
            appendPoints(seriesValues(coicop: code), key: MacroSeriesKey.itemKey(item.id), unit: item.unit)
        }

        let officialAsOf = latestHeadline.period
        let headlineName = country == .pt ? "HICP Portugal" : "HICP Euro Area"
        let headline = InflationGaugeDTO(
            name: headlineName,
            nowValue: latestHeadline.value,
            officialValue: latestHeadline.value,
            officialAsOf: officialAsOf
        )
        var gauges = [headline]
        if let core = coreValues.last {
            gauges.append(InflationGaugeDTO(name: "HICP Core (ex food & energy)", nowValue: core.value, officialValue: core.value, officialAsOf: core.period))
        }
        if let energy = energyValues.last {
            gauges.append(InflationGaugeDTO(name: "HICP Energy", nowValue: energy.value, officialValue: energy.value, officialAsOf: energy.period))
        }
        if let food = foodValues.last {
            gauges.append(InflationGaugeDTO(name: "HICP Food", nowValue: food.value, officialValue: food.value, officialAsOf: food.period))
        }

        var components: [InflationComponentDTO] = []
        var moverCandidates: [(mover: TopMoverDTO, magnitude: Double)] = []
        for division in divisions {
            let values = seriesValues(coicop: division.code)
            guard let latest = values.last else { continue }
            components.append(InflationComponentDTO(category: division.label, ourYoY: latest.value, blsYoY: latest.value))
            let previous = values.count >= 2 ? values[values.count - 2].value : nil
            let direction: String = if let previous {
                latest.value > previous ? "up" : (latest.value < previous ? "down" : "flat")
            } else {
                latest.value >= 0 ? "up" : "down"
            }
            moverCandidates.append((
                TopMoverDTO(category: division.label, changeYoY: latest.value, direction: direction),
                abs(latest.value)
            ))
        }
        let topMovers = moverCandidates.sorted { $0.magnitude > $1.magnitude }.prefix(6).map(\.mover)

        let sourceLabel = country == .pt
            ? "Eurostat HICP (INE Portugal) (\(officialAsOf))"
            : "Eurostat HICP + ECB (\(officialAsOf))"
        let snapshot = InflationSnapshotResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: latestHeadline.period + "-01",
            updatedAt: ISO8601DateFormatter().string(from: now),
            source: sourceLabel,
            headline: headline,
            gauges: gauges,
            components: components,
            topMovers: Array(topMovers)
        )
        return MacroProviderResult(snapshot: snapshot, points: points)
    }

    static func sincePeriod(yearsBack: Int, from date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date) - yearsBack
        return "\(year)-01"
    }

    private func fetchDataset(path: String, query: [(String, String)], on req: Request) async throws -> JSONStatDataset {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmed + path) else {
            throw Abort(.internalServerError, reason: "Invalid Eurostat base URL configuration.")
        }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build Eurostat request URL.")
        }
        let response = try await req.client.get(URI(string: url.absoluteString)) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(30)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Eurostat request failed with status \(response.status.code).")
        }
        do {
            return try response.content.decode(JSONStatDataset.self)
        } catch {
            throw Abort(.badGateway, reason: "Failed to decode Eurostat JSON-stat response.")
        }
    }
}

// MARK: - JSON-stat 2.0 decoding

/// Minimal JSON-stat 2.0 dataset decoder covering what Eurostat's
/// dissemination API returns: dimension ids/sizes, category indices, and a
/// sparse `value` object keyed by flattened linear index.
struct JSONStatDataset: Decodable {
    struct Dimension: Decodable {
        struct Category: Decodable {
            /// Category id → position. Eurostat emits this as an object.
            let index: [String: Int]?
            let label: [String: String]?
        }

        let category: Category
    }

    let id: [String]
    let size: [Int]
    let dimension: [String: Dimension]
    /// Sparse: flattened linear index (as string) → value.
    let value: [String: Double]

    /// Category ids for a dimension, ordered by their index position.
    func categoryIDs(dimension name: String) -> [String] {
        guard let index = dimension[name]?.category.index else { return [] }
        return index.sorted { $0.value < $1.value }.map(\.key)
    }

    /// Value at the given coordinates. Dimensions omitted from `coords` must
    /// have size 1 (e.g. a single geo/unit/freq in a filtered query).
    func value(at coords: [String: String]) -> Double? {
        var linear = 0
        for (position, dimensionID) in id.enumerated() {
            let dimensionSize = size[position]
            let categoryPosition: Int
            if let coordinate = coords[dimensionID] {
                guard let index = dimension[dimensionID]?.category.index?[coordinate] else { return nil }
                categoryPosition = index
            } else {
                guard dimensionSize == 1 else { return nil }
                categoryPosition = 0
            }
            linear = linear * dimensionSize + categoryPosition
        }
        return value[String(linear)]
    }
}
