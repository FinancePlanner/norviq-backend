import Vapor
import Foundation

struct MarketDataController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.get("market", "details", use: details)
        protected.get("market", "history", use: stockHistory)
        protected.get("market", "news", use: stockNews)
        protected.get("quote", "batch", use: quoteBatch)
        protected.get("quote", ":symbol", use: quote)
        protected.get("history", ":symbol", use: history)
        protected.get("search", use: search)
        protected.get("fx", use: fx)
    }

    @Sendable
    func details(req: Request) async throws -> StockDetailsResponse {
        let symbol = try requireSymbolQuery(req)
        let quote = try await req.application.marketDataService.quote(symbol: symbol, on: req)
        let company = await resolveCompanyName(for: quote.symbol, on: req)
        let changePercent = await resolveChangePercent(for: quote.symbol, latestPrice: quote.price, on: req)

        return StockDetailsResponse(
            symbol: quote.symbol,
            company: company,
            latestPrice: quote.price,
            changePercent: changePercent
        )
    }

    @Sendable
    func stockHistory(req: Request) async throws -> [StockHistory] {
        let symbol = try requireSymbolQuery(req)
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
    }

    @Sendable
    func stockNews(req: Request) async throws -> [StockNews] {
        let session = try req.auth.require(SessionToken.self)
        let symbol = try requireSymbolQuery(req)
        let items = try await req.application.newsService.list(
            userId: session.userId,
            symbol: symbol,
            on: req.db
        )

        return items.compactMap { item in
            guard let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                return nil
            }

            return StockNews(
                title: item.headline,
                url: url,
                date: item.publishedAt
            )
        }
    }

    @Sendable
    func quote(req: Request) async throws -> QuoteResponse {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.quote(symbol: symbol, on: req)
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
}
