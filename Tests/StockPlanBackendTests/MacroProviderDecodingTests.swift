import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Macro Provider Decoding Tests")
struct MacroProviderDecodingTests {
    // MARK: - FRED

    @Test("FRED observations skip '.' missing values and round to 2dp")
    func fredMissingValues() throws {
        let json = """
        {"observations": [
            {"date": "2026-04-01", "value": "3.412345"},
            {"date": "2026-05-01", "value": "."},
            {"date": "2026-06-01", "value": "2.9"}
        ]}
        """
        let decoded = try JSONDecoder().decode(FREDObservationsResponse.self, from: Data(json.utf8))
        let observations = FREDMacroProvider.parseObservations(decoded)
        #expect(observations.count == 2)
        #expect(observations[0] == .init(date: "2026-04-01", value: 3.41))
        #expect(observations[1] == .init(date: "2026-06-01", value: 2.9))
    }

    // MARK: - Eurostat JSON-stat

    /// Trimmed real-shape fixture: 1 geo × 2 coicop × 3 months, sparse value
    /// map (one missing observation).
    private let jsonStatFixture = """
    {
        "version": "2.0",
        "class": "dataset",
        "id": ["freq", "unit", "coicop", "geo", "time"],
        "size": [1, 1, 2, 1, 3],
        "dimension": {
            "freq": {"category": {"index": {"M": 0}, "label": {"M": "Monthly"}}},
            "unit": {"category": {"index": {"RCH_A": 0}, "label": {"RCH_A": "Annual rate of change"}}},
            "coicop": {"category": {"index": {"CP00": 0, "NRG": 1}, "label": {"CP00": "All-items HICP", "NRG": "Energy"}}},
            "geo": {"category": {"index": {"PT": 0}, "label": {"PT": "Portugal"}}},
            "time": {"category": {"index": {"2026-04": 0, "2026-05": 1, "2026-06": 2}}}
        },
        "value": {"0": 2.2, "1": 2.4, "2": 2.5, "3": -1.0, "5": -1.2}
    }
    """

    @Test("JSON-stat sparse value lookup by coordinates")
    func jsonStatLookup() throws {
        let dataset = try JSONDecoder().decode(JSONStatDataset.self, from: Data(jsonStatFixture.utf8))
        #expect(dataset.value(at: ["coicop": "CP00", "time": "2026-06"]) == 2.5)
        #expect(dataset.value(at: ["coicop": "NRG", "time": "2026-04"]) == -1.0)
        // Sparse hole: NRG 2026-05 is absent.
        #expect(dataset.value(at: ["coicop": "NRG", "time": "2026-05"]) == nil)
        #expect(dataset.value(at: ["coicop": "CP99", "time": "2026-06"]) == nil)
        #expect(dataset.categoryIDs(dimension: "time") == ["2026-04", "2026-05", "2026-06"])
    }

    @Test("Eurostat snapshot assembly from dataset")
    func eurostatSnapshot() throws {
        let dataset = try JSONDecoder().decode(JSONStatDataset.self, from: Data(jsonStatFixture.utf8))
        let result = try EurostatMacroProvider.buildResult(
            dataset: dataset,
            country: .pt,
            providerName: "eurostat",
            now: Date(timeIntervalSince1970: 1_783_000_000)
        )
        #expect(result.snapshot.country == "PT")
        #expect(result.snapshot.currency == "EUR")
        #expect(result.snapshot.headline.nowValue == 2.5)
        #expect(result.snapshot.headline.officialAsOf == "2026-06")
        // Headline history persisted for charts.
        let headlinePoints = result.points.filter { $0.seriesKey == "headline_cpi" }
        #expect(headlinePoints.count == 3)
        #expect(headlinePoints.first?.periodDate == "2026-04-01")
        // Energy gauge present from NRG series.
        #expect(result.snapshot.gauges.contains { $0.name == "HICP Energy" && $0.nowValue == -1.2 })
    }

    // MARK: - IBGE SIDRA

    @Test("SIDRA series parsing skips header row and missing values")
    func sidraSeriesParsing() {
        let rows: [[String: String]] = [
            ["V": "Valor", "D3C": "Mês (Código)"], // header row
            ["V": "4.42", "D3C": "202605"],
            ["V": "...", "D3C": "202606"],
            ["V": "4.52", "D3C": "202607"],
        ]
        let series = IBGEMacroProvider.parseSeries(rows: rows, periodKey: "D3C")
        #expect(series.count == 2)
        #expect(series[0] == .init(period: "2026-05-01", value: 4.42))
        #expect(series[1] == .init(period: "2026-07-01", value: 4.52))
    }

    @Test("SIDRA group parsing collects MoM and 12-month per classification")
    func sidraGroupParsing() {
        let rows: [[String: String]] = [
            ["V": "Valor", "D2C": "Variável", "D4C": "Grupo"], // header row
            ["V": "0.4", "D2C": "63", "D4C": "7170"],
            ["V": "6.1", "D2C": "2265", "D4C": "7170"],
            ["V": "-0.3", "D2C": "63", "D4C": "7625"],
            ["V": "-", "D2C": "2265", "D4C": "7625"],
        ]
        let groups = IBGEMacroProvider.parseGroups(rows: rows)
        #expect(groups["7170"] == .init(mom: 0.4, yoy: 6.1))
        #expect(groups["7625"] == .init(mom: -0.3, yoy: nil))
    }

    // MARK: - Nowflation tolerant decoding

    @Test("Nowflation payload resolves candidate keys and tolerates drift")
    func nowflationDecoding() throws {
        let json = """
        {
            "as_of": "2026-07-08",
            "gauge": {"yoy": 1.74},
            "col_yoy": "1.47",
            "cumulative": 33.9,
            "narrative": "Motor fuel remains the swing factor.",
            "unrelated_new_field": {"x": 1}
        }
        """
        let payload = try NowflationPayload.decode(from: Data(json.utf8))
        #expect(payload.gaugeYoY == 1.74)
        #expect(payload.colYoY == 1.47) // string-typed number tolerated
        #expect(payload.cumulativeSinceBase == 33.9)
        #expect(payload.asOf == "2026-07-08")
        #expect(payload.notes == "Motor fuel remains the swing factor.")
        #expect(payload.forecast == nil) // absent field degrades to nil
    }

    @Test("Nowflation enrichment merges gauge over official headline")
    func nowflationMerge() {
        let official = InflationGaugeDTO(name: "CPI (official, BLS)", nowValue: 4.2, officialValue: 4.2, officialAsOf: "2026-05")
        let base = MacroProviderResult(
            snapshot: InflationSnapshotResponse(
                country: "US", currency: "USD", asOf: "2026-05-01", updatedAt: "now",
                source: "BLS/BEA via FRED (2026-05)",
                headline: official, gauges: [official], components: [], topMovers: []
            ),
            points: []
        )
        var payload = NowflationPayload()
        payload.gaugeYoY = 1.74
        payload.colYoY = 1.47
        payload.asOf = "2026-07-08"
        let merged = NowflationEnrichment.apply(payload: payload, to: base, providerName: "nowflation", now: Date())
        #expect(merged.snapshot.headline.name == "Nowflation CPI")
        #expect(merged.snapshot.headline.nowValue == 1.74)
        #expect(merged.snapshot.headline.officialValue == 4.2)
        #expect(merged.snapshot.headline.gap == -2.46)
        #expect(merged.snapshot.source.hasPrefix("nowflation.com + "))
        #expect(merged.points.contains { $0.seriesKey == "nowflation_gauge" && $0.value == 1.74 })
    }

    @Test("Nowflation payload without a gauge leaves the result untouched")
    func nowflationNoGauge() {
        let official = InflationGaugeDTO(name: "CPI (official, BLS)", nowValue: 4.2, officialValue: 4.2, officialAsOf: "2026-05")
        let base = MacroProviderResult(
            snapshot: InflationSnapshotResponse(
                country: "US", currency: "USD", asOf: "2026-05-01", updatedAt: "now",
                source: "BLS/BEA via FRED (2026-05)",
                headline: official, gauges: [official], components: [], topMovers: []
            ),
            points: []
        )
        let merged = NowflationEnrichment.apply(payload: NowflationPayload(), to: base, providerName: "nowflation", now: Date())
        #expect(merged.snapshot.headline.name == "CPI (official, BLS)")
        #expect(merged.points.isEmpty)
    }

    // MARK: - Calendars

    @Test("next FOMC meeting and CPI print countdowns")
    func calendars() throws {
        let formatter = FOMCCalendar.dayFormatter
        let today = try #require(formatter.date(from: "2026-07-09"))
        let meeting = FOMCCalendar.nextMeeting(after: today)
        #expect(meeting?.startDate == "2026-07-28")
        #expect(meeting?.daysRemaining == 19)
        #expect(meeting?.odds == nil)

        let print = BLSCPIReleaseCalendar.nextPrint(after: today, lastOfficial: 4.2)
        #expect(print?.date == "2026-07-14")
        #expect(print?.daysRemaining == 5)
        #expect(print?.lastOfficial == 4.2)
    }
}
