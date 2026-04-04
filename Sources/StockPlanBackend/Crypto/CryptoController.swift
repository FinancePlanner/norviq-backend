import Vapor
import Foundation

struct CryptoController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let crypto = protected.grouped("crypto")

        // Market data endpoints
        crypto.get("list", use: cryptocurrencyList)
        crypto.get("quote", ":symbol", use: quote)
        crypto.get("quote-short", ":symbol", use: quoteShort)
        crypto.get("batch-quotes", use: batchQuotes)
        crypto.get("history", "light", ":symbol", use: historicalLight)
        crypto.get("history", "full", ":symbol", use: historicalFull)
        crypto.get("history", "1min", ":symbol", use: intraday1min)
        crypto.get("history", "5min", ":symbol", use: intraday5min)
        crypto.get("history", "1hour", ":symbol", use: intraday1hour)

        // Portfolio CRUD
        let portfolio = crypto.grouped("portfolio")
        portfolio.get(use: listPortfolio)
        portfolio.post(use: addToPortfolio)
        portfolio.group(":itemId") { item in
            item.put(use: updatePortfolioItem)
            item.delete(use: removeFromPortfolio)
        }
    }

    // MARK: - Market Data

    @Sendable
    func cryptocurrencyList(req: Request) async throws -> [CryptoAssetResponse] {
        try await req.application.cryptoService.cryptocurrencyList(on: req)
    }

    @Sendable
    func quote(req: Request) async throws -> [CryptoQuoteResponse] {
        let symbols = try requireSymbolParameter(req)
        return try await req.application.cryptoService.quote(symbols: symbols, on: req)
    }

    @Sendable
    func quoteShort(req: Request) async throws -> [CryptoQuoteShortResponse] {
        let symbol = try requireSymbolParameter(req)
        return try await req.application.cryptoService.quoteShort(symbol: symbol, on: req)
    }

    @Sendable
    func batchQuotes(req: Request) async throws -> [CryptoQuoteShortResponse] {
        let short = req.query[Bool.self, at: "short"] ?? false
        return try await req.application.cryptoService.batchQuotes(short: short, on: req)
    }

    @Sendable
    func historicalLight(req: Request) async throws -> [CryptoHistoricalLightPoint] {
        let symbol = try requireSymbolParameter(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.cryptoService.historicalLight(
            symbol: symbol, from: from, to: to, on: req
        )
    }

    @Sendable
    func historicalFull(req: Request) async throws -> [CryptoHistoricalFullPoint] {
        let symbol = try requireSymbolParameter(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.cryptoService.historicalFull(
            symbol: symbol, from: from, to: to, on: req
        )
    }

    @Sendable
    func intraday1min(req: Request) async throws -> [CryptoHistoricalPoint] {
        let symbol = try requireSymbolParameter(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.cryptoService.intraday1min(
            symbol: symbol, from: from, to: to, on: req
        )
    }

    @Sendable
    func intraday5min(req: Request) async throws -> [CryptoHistoricalPoint] {
        let symbol = try requireSymbolParameter(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.cryptoService.intraday5min(
            symbol: symbol, from: from, to: to, on: req
        )
    }

    @Sendable
    func intraday1hour(req: Request) async throws -> [CryptoHistoricalPoint] {
        let symbol = try requireSymbolParameter(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.cryptoService.intraday1hour(
            symbol: symbol, from: from, to: to, on: req
        )
    }

    // MARK: - Portfolio

    @Sendable
    func listPortfolio(req: Request) async throws -> [CryptoPortfolioItemResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.cryptoService.listPortfolio(
            userId: session.userId, on: req.db
        )
    }

    @Sendable
    func addToPortfolio(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(CryptoPortfolioItemRequest.self)
        let created = try await req.application.cryptoService.addToPortfolio(
            payload: payload, userId: session.userId, on: req.db
        )
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updatePortfolioItem(req: Request) async throws -> CryptoPortfolioItemResponse {
        let session = try req.auth.require(SessionToken.self)
        let itemId = try requireUUIDParameter(req, name: "itemId")
        let payload = try req.content.decode(CryptoPortfolioItemRequest.self)
        return try await req.application.cryptoService.updatePortfolioItem(
            id: itemId, payload: payload, userId: session.userId, on: req.db
        )
    }

    @Sendable
    func removeFromPortfolio(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let itemId = try requireUUIDParameter(req, name: "itemId")
        try await req.application.cryptoService.removeFromPortfolio(
            id: itemId, userId: session.userId, on: req.db
        )
        return .noContent
    }

    // MARK: - Helpers

    private func requireSymbolParameter(_ req: Request) throws -> String {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return trimmed
    }

    private func requireUUIDParameter(_ req: Request, name: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name).")
        }
        return value
    }
}
