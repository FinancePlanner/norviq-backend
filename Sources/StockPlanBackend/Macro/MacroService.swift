import Foundation
import StockPlanShared
import Vapor

/// MVP implementation of macro/inflation service.
/// Currently returns realistic stub data for multiple countries.
/// This will later delegate to pluggable providers (Nowflation, FRED, Eurostat, IBGE, etc.).
struct MacroService {
    func getCurrentInflation(country: String) async throws -> InflationSnapshotResponse {
        let normalized = country.uppercased()
        let now = ISO8601DateFormatter().string(from: Date())

        switch normalized {
        case "US":
            return makeUSSnapshot(now: now)
        case "BR":
            return makeBrazilSnapshot(now: now)
        case "PT", "EA", "EURO":
            return makeEuroAreaSnapshot(now: now, countryCode: normalized)
        default:
            // MVP fallback: US data
            return makeUSSnapshot(now: now)
        }
    }

    func getSupportedCountries() async throws -> [SupportedCountry] {
        [
            SupportedCountry(
                code: "US",
                name: "United States",
                currency: "USD",
                dataSource: "Nowflation + BLS",
                hasDailyData: true
            ),
            SupportedCountry(
                code: "BR",
                name: "Brazil",
                currency: "BRL",
                dataSource: "IBGE IPCA + BCB",
                hasDailyData: false
            ),
            SupportedCountry(
                code: "PT",
                name: "Portugal",
                currency: "EUR",
                dataSource: "INE Portugal + Eurostat HICP",
                hasDailyData: false
            ),
            SupportedCountry(
                code: "EA",
                name: "Euro Area",
                currency: "EUR",
                dataSource: "Eurostat HICP + ECB",
                hasDailyData: false
            ),
        ]
    }

    // MARK: - Private stub data generators (MVP)

    private func makeUSSnapshot(now: String) -> InflationSnapshotResponse {
        let headline = InflationGaugeDTO(
            name: "Nowflation CPI",
            nowValue: 1.74,
            officialValue: 4.2,
            officialAsOf: "2026-05",
            gap: -2.46,
            unit: "percent",
            colVariant: 1.47,
            cumulativeSinceBase: 33.9,
            basePeriod: "2018-01"
        )

        let gauges: [InflationGaugeDTO] = [
            headline,
            InflationGaugeDTO(name: "Core CPI (Nowflation Forecast)", nowValue: 2.87, officialValue: 2.9, officialAsOf: "2026-05", gap: -0.03),
            InflationGaugeDTO(name: "Supercore (svcs ex-shelter)", nowValue: 2.01, officialValue: nil, officialAsOf: nil, gap: nil),
            InflationGaugeDTO(name: "PCE (PCE-weighted gauge)", nowValue: 2.04, officialValue: 4.07, officialAsOf: "2026-05", gap: -2.03),
            InflationGaugeDTO(name: "Core PCE (Fed 2% target)", nowValue: 3.4, officialValue: 3.41, officialAsOf: "2026-05", gap: -0.01),
        ]

        let components: [InflationComponentDTO] = [
            .init(category: "Shelter: Rent", ourYoY: 0.8, blsYoY: 2.9, cpiWeight: 7.5),
            .init(category: "Shelter: Owned", ourYoY: 3.3, blsYoY: 3.3, cpiWeight: 26.5),
            .init(category: "Motor Fuel", ourYoY: 41.6, blsYoY: 41.6, cpiWeight: 3.0),
            .init(category: "Used Vehicles", ourYoY: -2.0, blsYoY: -2.0, cpiWeight: 2.1),
            .init(category: "New Vehicles", ourYoY: 0.2, blsYoY: 0.2, cpiWeight: 3.6),
            .init(category: "Food at Home", ourYoY: 2.7, blsYoY: 2.7, cpiWeight: 8.2),
            .init(category: "Food Away", ourYoY: 3.5, blsYoY: 3.5, cpiWeight: 5.7),
            .init(category: "Electricity", ourYoY: 8.4, blsYoY: 5.9, cpiWeight: 2.8),
            .init(category: "Utility Gas", ourYoY: -5.6, blsYoY: 3.0, cpiWeight: 0.7),
            .init(category: "Medical Care", ourYoY: 2.6, blsYoY: 2.6, cpiWeight: 8.1),
            .init(category: "Apparel", ourYoY: 4.8, blsYoY: 4.8, cpiWeight: 2.5),
            .init(category: "Recreation", ourYoY: 2.6, blsYoY: 2.6, cpiWeight: 5.3),
            .init(category: "Education & Comm", ourYoY: 0.8, blsYoY: 0.8, cpiWeight: 5.5),
            .init(category: "Everything Else", ourYoY: 2.8, blsYoY: 2.8, cpiWeight: 18.5),
        ]

        let topMovers: [TopMoverDTO] = [
            .init(category: "Utility Gas", changeYoY: -5.6, changeMoM: nil, weight: 0.7, direction: "down"),
            .init(category: "Food at Home", changeYoY: 2.7, changeMoM: nil, weight: 8.2, direction: "up"),
            .init(category: "Apparel", changeYoY: 4.8, changeMoM: nil, weight: 2.5, direction: "up"),
            .init(category: "Shelter: Owned", changeYoY: 3.3, changeMoM: nil, weight: 26.5, direction: "up"),
            .init(category: "Everything Else", changeYoY: 2.8, changeMoM: nil, weight: 18.5, direction: "up"),
            .init(category: "Motor Fuel", changeYoY: 41.6, changeMoM: -12.12, weight: 3.0, direction: "down"),
        ]

        return InflationSnapshotResponse(
            country: "US",
            currency: "USD",
            asOf: "2026-07-08",
            updatedAt: now,
            source: "nowflation.com + BLS (2026-07-08)",
            headline: headline,
            gauges: gauges,
            components: components,
            topMovers: topMovers,
            notes: "Nowflation Gauge holds at 1.73% YoY (+0.03pp DoD). Motor fuel remains the swing factor. Shelter components diverge (Owned 2.72% vs Rent 0.69%).",
            nextPrintCountdown: NextPrintDTO(
                date: "2026-07-??",
                daysRemaining: 5,
                forecastNowflation: 4.025,
                streetConsensus: 3.9,
                lastOfficial: 4.2
            )
        )
    }

    private func makeBrazilSnapshot(now: String) -> InflationSnapshotResponse {
        let headline = InflationGaugeDTO(
            name: "IPCA",
            nowValue: 4.52,
            officialValue: 4.52,
            officialAsOf: "2026-06",
            gap: nil,
            unit: "percent"
        )

        let gauges: [InflationGaugeDTO] = [
            headline,
            InflationGaugeDTO(name: "IPCA Ex-Food and Energy", nowValue: 3.8, officialValue: 3.8, officialAsOf: "2026-06"),
            InflationGaugeDTO(name: "IPCA Food", nowValue: 6.1, officialValue: 6.1, officialAsOf: "2026-06"),
        ]

        let components: [InflationComponentDTO] = [
            .init(category: "Alimentos e bebidas", ourYoY: 6.1, blsYoY: 6.1),
            .init(category: "Habitação", ourYoY: 3.9, blsYoY: 3.9),
            .init(category: "Transportes", ourYoY: 2.8, blsYoY: 2.8),
            .init(category: "Saúde e cuidados pessoais", ourYoY: 5.2, blsYoY: 5.2),
            .init(category: "Despesas pessoais", ourYoY: 4.1, blsYoY: 4.1),
            .init(category: "Educação", ourYoY: 5.5, blsYoY: 5.5),
            .init(category: "Comunicação", ourYoY: 1.2, blsYoY: 1.2),
            .init(category: "Vestuário", ourYoY: 3.4, blsYoY: 3.4),
        ]

        let topMovers: [TopMoverDTO] = [
            .init(category: "Alimentos e bebidas", changeYoY: 6.1, changeMoM: 0.4, weight: nil, direction: "up"),
            .init(category: "Transportes", changeYoY: 2.8, changeMoM: -0.3, weight: nil, direction: "up"),
            .init(category: "Habitação", changeYoY: 3.9, changeMoM: 0.1, weight: nil, direction: "up"),
            .init(category: "Saúde e cuidados pessoais", changeYoY: 5.2, changeMoM: 0.2, weight: nil, direction: "up"),
        ]

        return InflationSnapshotResponse(
            country: "BR",
            currency: "BRL",
            asOf: "2026-07-08",
            updatedAt: now,
            source: "IBGE (IPCA) + BCB (2026-06)",
            headline: headline,
            gauges: gauges,
            components: components,
            topMovers: topMovers,
            notes: "IPCA acumulado em 12 meses. Alimentos continuam como principal pressão inflacionária.",
            nextPrintCountdown: nil
        )
    }

    private func makeEuroAreaSnapshot(now: String, countryCode: String) -> InflationSnapshotResponse {
        let displayCountry = (countryCode == "PT") ? "PT" : "EA"
        let source = (countryCode == "PT") ? "INE Portugal + Eurostat HICP" : "Eurostat HICP + ECB"

        let headline = InflationGaugeDTO(
            name: (countryCode == "PT") ? "HICP Portugal" : "HICP Euro Area",
            nowValue: 2.5,
            officialValue: 2.5,
            officialAsOf: "2026-06",
            gap: nil,
            unit: "percent"
        )

        let gauges: [InflationGaugeDTO] = [
            headline,
            InflationGaugeDTO(name: "HICP Core (ex food & energy)", nowValue: 2.8, officialValue: 2.8, officialAsOf: "2026-06"),
            InflationGaugeDTO(name: "HICP Energy", nowValue: -1.2, officialValue: -1.2, officialAsOf: "2026-06"),
        ]

        let components: [InflationComponentDTO] = [
            .init(category: "Food and non-alcoholic beverages", ourYoY: 3.1, blsYoY: 3.1),
            .init(category: "Housing, water, electricity, gas", ourYoY: 2.9, blsYoY: 2.9),
            .init(category: "Transport", ourYoY: 1.4, blsYoY: 1.4),
            .init(category: "Restaurants and hotels", ourYoY: 4.2, blsYoY: 4.2),
            .init(category: "Recreation and culture", ourYoY: 2.1, blsYoY: 2.1),
        ]

        let topMovers: [TopMoverDTO] = [
            .init(category: "Restaurants and hotels", changeYoY: 4.2, direction: "up"),
            .init(category: "Food and non-alcoholic beverages", changeYoY: 3.1, direction: "up"),
            .init(category: "Housing, water, electricity, gas", changeYoY: 2.9, direction: "up"),
            .init(category: "Energy", changeYoY: -1.2, direction: "down"),
        ]

        return InflationSnapshotResponse(
            country: displayCountry,
            currency: "EUR",
            asOf: "2026-07-08",
            updatedAt: now,
            source: source + " (2026-06)",
            headline: headline,
            gauges: gauges,
            components: components,
            topMovers: topMovers,
            notes: (countryCode == "PT")
                ? "HICP Portugal alinhado com a média da área do euro. Energia continua a contribuir negativamente."
                : "HICP Euro Area. Services remain the main driver of underlying inflation.",
            nextPrintCountdown: nil
        )
    }
}
