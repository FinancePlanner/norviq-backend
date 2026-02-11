import Vapor

struct StatisticsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let statistics = protected.grouped("statistics")
        let stocks = statistics.grouped("stocks")

        stocks.get("scorecard", use: getStockLevelScorecard)
        stocks.get("allocation", use: getStockAllocation)
        stocks.get("sector-allocation", use: getSectorAllocation)
        stocks.get("calendar-performance", use: getCalendarPerformance)
        stocks.get("contribution-analysis", use: getContributionAnalysis)
        stocks.get("winners-losers", use: getWinnersVsLosers)
        stocks.get("volatility-snapshot", use: getVolatilitySnapshot)
        stocks.get("currency-split", use: getCurrencySplit)
        stocks.get("scenario-tracking", use: getScenarioTracking)
        stocks.get("notes-quality", use: getNotesQualityMetrics)

        statistics.get("imported-stocks", use: getImportedStocksStatistics)
        statistics.get("watchlist", use: getWatchlistStatistics)
        statistics.get("looklist", use: getLooklistStatistics)
        statistics.get("market", use: getMarketStatistics)
        statistics.get("overview", use: getOverviewStatistics)
    }

    @Sendable
    func getStockLevelScorecard(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Stock-level scorecard is not implemented yet.")
    }

    @Sendable
    func getStockAllocation(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Stock allocation statistics are not implemented yet.")
    }

    @Sendable
    func getSectorAllocation(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Sector allocation statistics are not implemented yet.")
    }

    @Sendable
    func getCalendarPerformance(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Calendar performance statistics are not implemented yet.")
    }

    @Sendable
    func getContributionAnalysis(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Contribution analysis is not implemented yet.")
    }

    @Sendable
    func getWinnersVsLosers(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Winners vs losers statistics are not implemented yet.")
    }

    @Sendable
    func getVolatilitySnapshot(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Volatility snapshot is not implemented yet.")
    }

    @Sendable
    func getCurrencySplit(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Currency split statistics are not implemented yet.")
    }

    @Sendable
    func getScenarioTracking(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Scenario tracking is not implemented yet.")
    }

    @Sendable
    func getNotesQualityMetrics(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Notes quality metrics are not implemented yet.")
    }

    @Sendable
    func getImportedStocksStatistics(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Imported stocks statistics are not implemented yet.")
    }

    @Sendable
    func getWatchlistStatistics(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Watchlist statistics are not implemented yet.")
    }

    @Sendable
    func getLooklistStatistics(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Looklist statistics are not implemented yet.")
    }

    @Sendable
    func getMarketStatistics(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Market statistics are not implemented yet.")
    }

    @Sendable
    func getOverviewStatistics(req: Request) async throws -> StatisticsDTO {
        throw Abort(.notImplemented, reason: "Overview statistics are not implemented yet.")
    }
}
