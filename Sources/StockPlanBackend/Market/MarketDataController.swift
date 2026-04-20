import Vapor
import Foundation
import StockPlanShared

struct MarketDataController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let market = protected.grouped("market")

        market.get("details", use: details)
        market.get("history", use: stockHistory)
        market.get("history", "archive", use: archivedStockHistory)
        market.post("history", "archive", "sync", use: syncArchivedStockHistory)
        market.get("news", use: stockNews)
        market.get("news", "general", use: generalMarketNews)
        market.get("news", "archive", use: archivedStockNews)
        market.post("news", "archive", "sync", use: syncArchivedStockNews)

        market.get("quote", "batch", use: quoteBatch)
        market.get("quote", ":symbol", use: quote)
        market.get("profile", ":symbol", use: profile)
        market.get("basic-financials", ":symbol", use: basicFinancials)
        market.get("analysis", ":symbol", use: analysis)
        market.get("compare", use: compare)
        market.get("cash-flow-statement", ":symbol", use: cashFlowStatement)
        market.get("balance-sheet-statement", ":symbol", use: balanceSheetStatement)
        market.get("ratios-ttm", ":symbol", use: ratiosTTM)
        market.get("grades-consensus", ":symbol", use: gradesConsensus)
        market.get("financial-growth", ":symbol", use: financialGrowth)
        market.get("earnings", ":symbol", use: earnings)
        market.get("earnings-calendar", use: earningsCalendar)
        market.get("analyst-estimates", ":symbol", use: analystEstimates)
        market.get("ratios", ":symbol", use: ratios)
        market.get("historical-sector-performance", use: historicalSectorPerformance)
        market.get("history", ":symbol", use: history)
        market.get("search", use: search)
        market.get("fx", use: fx)
        market.get("price-chart", "compare", use: priceChartComparison)
        market.get("price-chart", ":symbol", use: priceChart)
    }

    @Sendable
    func details(req: Request) async throws -> StockDetailsResponse {
        let symbol = try requireSymbolQuery(req)
        do {
            let quote = try await req.application.marketDataService.quote(symbol: symbol, on: req)
            let company = await resolveCompanyName(for: quote.symbol, on: req)
            let changePercent = await resolveChangePercent(
                for: quote.symbol,
                latestPrice: quote.currentPrice,
                on: req
            )

            return StockDetailsResponse(
                symbol: quote.symbol,
                company: company,
                latestPrice: quote.currentPrice,
                changePercent: changePercent
            )
        } catch is MarketDataProviderDisabledError {
            return StockDetailsResponse(
                symbol: symbol.uppercased(),
                company: symbol.uppercased(),
                latestPrice: 0,
                changePercent: 0
            )
        }
    }

    @Sendable
    func stockHistory(req: Request) async throws -> [StockHistory] {
        let symbol = try requireSymbolQuery(req)
        do {
            let response = try await req.application.marketDataService.history(
                symbol: symbol,
                from: nil,
                to: nil,
                on: req
            )

            return response.bars
                .sorted { $0.date > $1.date }
                .map {
                    StockHistory(
                        date: $0.date,
                        open: $0.open,
                        high: $0.high,
                        low: $0.low,
                        close: $0.close,
                        volume: $0.volume ?? 0
                    )
                }
        } catch is MarketDataProviderDisabledError {
            return []
        }
    }

    @Sendable
    func archivedStockHistory(req: Request) async throws -> [StockHistory] {
        let symbol = try requireSymbolQuery(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        let response = try await req.application.marketDataService.archivedHistory(
            symbol: symbol,
            from: from,
            to: to,
            on: req
        )
        return makeStockHistory(response)
    }

    @Sendable
    func syncArchivedStockHistory(req: Request) async throws -> [StockHistory] {
        let symbol = try requireSymbolQuery(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        let response = try await req.application.marketDataService.refreshHistory(
            symbol: symbol,
            from: from,
            to: to,
            on: req
        )
        return makeStockHistory(response)
    }

    @Sendable
    func stockNews(req: Request) async throws -> [StockNews] {
        let symbol = try requireSymbolQuery(req)
        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketNewsArchiveService.news(
            symbol: symbol,
            limit: limit,
            on: req
        )
    }

    @Sendable
    func generalMarketNews(req: Request) async throws -> [StockNews] {
        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketNewsArchiveService.generalNews(
            limit: limit,
            on: req
        )
    }

    @Sendable
    func archivedStockNews(req: Request) async throws -> [StockNews] {
        let symbol = try requireSymbolQuery(req)
        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketNewsArchiveService.archivedNews(
            symbol: symbol,
            limit: limit,
            on: req.db
        )
    }

    @Sendable
    func syncArchivedStockNews(req: Request) async throws -> [StockNews] {
        let symbol = try requireSymbolQuery(req)
        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketNewsArchiveService.refreshNews(
            symbol: symbol,
            limit: limit,
            on: req
        )
    }

    @Sendable
    func quote(req: Request) async throws -> QuoteResponse {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.quote(symbol: symbol, on: req)
    }

    @Sendable
    func profile(req: Request) async throws -> CompanyProfileResponse {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.profile(symbol: symbol, on: req)
    }

    @Sendable
    func basicFinancials(req: Request) async throws -> BasicFinancialsResponse {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.basicFinancials(symbol: symbol, on: req)
    }

    @Sendable
    func analysis(req: Request) async throws -> StockAnalysisMetricsResponse {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.analysis(symbol: symbol, on: req)
    }

    @Sendable
    func compare(req: Request) async throws -> [StockAnalysisMetricsResponse] {
        guard let symbolsStr = req.query[String.self, at: "symbols"] else {
            throw Abort(.badRequest, reason: "Missing symbols query parameter.")
        }
        let symbols = symbolsStr.split(separator: ",").map(String.init)
        return try await req.application.marketDataService.compare(symbols: symbols, on: req)
    }

    @Sendable
    func cashFlowStatement(req: Request) async throws -> [CashFlowStatementResponse] {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]
        return try await req.application.marketDataService.cashFlowStatement(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func balanceSheetStatement(req: Request) async throws -> [BalanceSheetStatementResponse] {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]
        return try await req.application.marketDataService.balanceSheetStatement(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func ratiosTTM(req: Request) async throws -> [RatiosTTMResponse] {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.ratiosTTM(symbol: symbol, on: req)
    }

    @Sendable
    func gradesConsensus(req: Request) async throws -> [GradesConsensusResponse] {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.gradesConsensus(symbol: symbol, on: req)
    }

    @Sendable
    func financialGrowth(req: Request) async throws -> [FinancialGrowthResponse] {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]
        return try await req.application.marketDataService.financialGrowth(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func earnings(req: Request) async throws -> [EarningsResponse] {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketDataService.earnings(
            symbol: symbol,
            limit: limit,
            on: req
        )
    }

    @Sendable
    func earningsCalendar(req: Request) async throws -> [EarningsResponse] {
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.marketDataService.earningsCalendar(
            from: from,
            to: to,
            on: req
        )
    }

    @Sendable
    func analystEstimates(req: Request) async throws -> [AnalystEstimatesResponse] {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let period = req.query[String.self, at: "period"] ?? "annual"
        let page = req.query[Int.self, at: "page"]
        let limit = req.query[Int.self, at: "limit"]

        return try await req.application.marketDataService.analystEstimates(
            symbol: symbol,
            period: period,
            page: page,
            limit: limit,
            on: req
        )
    }

    @Sendable
    func ratios(req: Request) async throws -> [RatiosResponse] {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]

        return try await req.application.marketDataService.ratios(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func historicalSectorPerformance(req: Request) async throws -> [HistoricalSectorPerformanceResponse] {
        guard let sector = req.query[String.self, at: "sector"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `sector`.")
        }

        let exchange = req.query[String.self, at: "exchange"]
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.marketDataService.historicalSectorPerformance(
            sector: sector,
            exchange: exchange,
            from: from,
            to: to,
            on: req
        )
    }

    @Sendable
    func quoteBatch(req: Request) async throws -> QuoteBatchResponse {
        guard let symbols = req.query[String.self, at: "symbols"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `symbols`.")
        }

        let parsed = symbols
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return try await req.application.marketDataService.quoteBatch(symbols: parsed, on: req)
    }

    @Sendable
    func history(req: Request) async throws -> HistoryResponse {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.marketDataService.history(symbol: symbol, from: from, to: to, on: req)
    }

    @Sendable
    func search(req: Request) async throws -> [SearchResultResponse] {
        guard let query = req.query[String.self, at: "q"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `q`.")
        }
        return try await req.application.marketDataService.search(query: query, on: req)
    }

    @Sendable
    func fx(req: Request) async throws -> FxRateResponse {
        let pair = req.query[String.self, at: "pair"] ?? "EURUSD"
        return try await req.application.marketDataService.fx(pair: pair, on: req)
    }

    private func requireSymbolQuery(_ req: Request) throws -> String {
        guard let symbol = req.query[String.self, at: "symbol"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !symbol.isEmpty
        else {
            throw Abort(.badRequest, reason: "Missing query parameter `symbol`.")
        }
        return symbol
    }

    // MARK: - Price Chart

    @Sendable
    func priceChart(req: Request) async throws -> PriceChartSeries {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        let range = req.query[String.self, at: "range"] ?? "1D"
        return try await req.application.marketDataService.priceChart(
            symbol: symbol, range: range, on: req
        )
    }

    @Sendable
    func priceChartComparison(req: Request) async throws -> PriceChartComparisonResponse {
        guard let symbolsStr = req.query[String.self, at: "symbols"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `symbols`.")
        }
        let symbols = symbolsStr.split(separator: ",").map(String.init)
        let range = req.query[String.self, at: "range"] ?? "1D"
        return try await req.application.marketDataService.priceChartComparison(
            symbols: symbols, range: range, on: req
        )
    }

    private func resolveCompanyName(for symbol: String, on req: Request) async -> String {
        do {
            let results = try await req.application.marketDataService.search(query: symbol, on: req)
            if let exact = results.first(where: { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }) {
                return exact.name
            }
            return results.first?.name ?? symbol
        } catch {
            req.logger.debug("market.details company fallback symbol=\(symbol) error=\(error.localizedDescription)")
            return symbol
        }
    }

    private func resolveChangePercent(for symbol: String, latestPrice: Double, on req: Request) async -> Double {
        do {
            let response = try await req.application.marketDataService.history(
                symbol: symbol,
                from: nil,
                to: nil,
                on: req
            )
            return calculateChangePercent(latestPrice: latestPrice, bars: response.bars)
        } catch {
            req.logger.debug("market.details change fallback symbol=\(symbol) error=\(error.localizedDescription)")
            return 0
        }
    }

    private func calculateChangePercent(latestPrice: Double, bars: [PriceBarResponse]) -> Double {
        let sorted = bars.sorted { $0.date < $1.date }

        if sorted.count >= 2 {
            let previousClose = sorted[sorted.count - 2].close
            guard previousClose != 0 else { return 0 }
            return (latestPrice - previousClose) / previousClose
        }

        if let latestBar = sorted.last, latestBar.open != 0 {
            return (latestBar.close - latestBar.open) / latestBar.open
        }

        return 0
    }

    private func makeStockHistory(_ response: HistoryResponse) -> [StockHistory] {
        response.bars
            .sorted { $0.date > $1.date }
            .map {
                StockHistory(
                    date: $0.date,
                    open: $0.open,
                    high: $0.high,
                    low: $0.low,
                    close: $0.close,
                    volume: $0.volume ?? 0
                )
            }
    }
}
