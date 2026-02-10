import Vapor
import Foundation

struct MarketDataController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.get("quote", ":symbol", use: quote)
        protected.get("history", ":symbol", use: history)
        protected.get("search", use: search)
        protected.get("fx", use: fx)
    }

    @Sendable
    func quote(req: Request) async throws -> QuoteResponse {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.quote(symbol: symbol, on: req)
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
}
