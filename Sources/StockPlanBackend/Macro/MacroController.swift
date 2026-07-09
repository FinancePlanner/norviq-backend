import Foundation
import StockPlanShared
import Vapor

/// Macro / Inflation controller (global Nowflation-style data).
/// MVP implementation supporting multiple countries via query param.
struct MacroController: RouteCollection {
    private let macroService = MacroService()

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let macro = protected.grouped("macro")
        let rateLimited = macro.grouped(RateLimitMiddleware(limit: 80, interval: 60, keyPrefix: "ratelimit:macro"))

        rateLimited.get("inflation", "current", use: getCurrentInflation)
        rateLimited.get("inflation", "components", use: getComponents)
        rateLimited.get("top-movers", use: getTopMovers)
        rateLimited.get("inflation", "series", use: getSeries)
        rateLimited.get("supported-countries", use: getSupportedCountries)
    }

    // MARK: - Current Snapshot (main MVP endpoint)

    @Sendable
    func getCurrentInflation(req: Request) async throws -> InflationSnapshotResponse {
        let country = req.query[String.self, at: "country"] ?? "US"
        return try await macroService.getCurrentInflation(country: country)
    }

    // MARK: - Components

    @Sendable
    func getComponents(req: Request) async throws -> [InflationComponentDTO] {
        let snapshot = try await getCurrentInflation(req: req)
        return snapshot.components
    }

    // MARK: - Top Movers

    @Sendable
    func getTopMovers(req: Request) async throws -> [TopMoverDTO] {
        let snapshot = try await getCurrentInflation(req: req)

        if let focus = req.query[String.self, at: "focus"] {
            let wanted = focus.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return snapshot.topMovers.filter { mover in
                wanted.contains { mover.category.lowercased().contains($0) }
            }
        }
        return snapshot.topMovers
    }

    // MARK: - Series (history)

    @Sendable
    func getSeries(req: Request) async throws -> MacroSeriesResponse {
        let country = req.query[String.self, at: "country"] ?? "US"
        let series = req.query[String.self, at: "series"] ?? (country.uppercased() == "US" ? "nowflation_cpi" : "headline")

        // MVP stub history — will be replaced by real time series later
        let baseValue: Double = country.uppercased() == "US" ? 1.71 : (country.uppercased() == "BR" ? 4.3 : 2.3)
        let points: [MacroSeriesPoint] = [
            .init(date: "2026-06-01", value: baseValue, series: series),
            .init(date: "2026-06-08", value: baseValue + 0.01, series: series),
            .init(date: "2026-06-15", value: baseValue + 0.02, series: series),
            .init(date: "2026-06-22", value: baseValue + 0.03, series: series),
            .init(date: "2026-07-01", value: baseValue + 0.04, series: series),
            .init(date: "2026-07-08", value: country.uppercased() == "US" ? 1.74 : (country.uppercased() == "BR" ? 4.52 : 2.5), series: series),
        ]
        return MacroSeriesResponse(series: series, points: points)
    }

    // MARK: - Supported Countries

    @Sendable
    func getSupportedCountries(req _: Request) async throws -> [SupportedCountry] {
        try await macroService.getSupportedCountries()
    }
}
