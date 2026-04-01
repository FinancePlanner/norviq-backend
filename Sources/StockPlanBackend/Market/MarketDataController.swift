import Vapor
import Foundation

struct MarketDataController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.get("market", "details", use: details)
        protected.get("market", "history", use: stockHistory)
        protected.get("market", "history", "archive", use: archivedStockHistory)
        protected.post("market", "history", "archive", "sync", use: syncArchivedStockHistory)
        protected.get("market", "news", use: stockNews)
        protected.get("market", "news", "archive", use: archivedStockNews)
        protected.post("market", "news", "archive", "sync", use: syncArchivedStockNews)
        protected.get("quote", "batch", use: quoteBatch)
        protected.get("quote", ":symbol", use: quote)
        protected.get("profile", ":symbol", use: profile)
        protected.get("history", ":symbol", use: history)
        protected.get("search", use: search)
        protected.get("fx", use: fx)
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
