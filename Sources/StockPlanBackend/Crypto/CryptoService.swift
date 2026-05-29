import Fluent
import Foundation
import Vapor

protocol CryptoService: Sendable {
    // Portfolio CRUD
    func listPortfolio(userId: UUID, on db: any Database) async throws -> [CryptoPortfolioItemResponse]
    func addToPortfolio(payload: CryptoPortfolioItemRequest, userId: UUID, on db: any Database) async throws -> CryptoPortfolioItemResponse
    func updatePortfolioItem(id: UUID, payload: CryptoPortfolioItemRequest, userId: UUID, on db: any Database) async throws -> CryptoPortfolioItemResponse
    func removeFromPortfolio(id: UUID, userId: UUID, on db: any Database) async throws

    // Watchlist CRUD
    func listWatchlist(userId: UUID, on db: any Database) async throws -> [CryptoWatchlistItemResponse]
    func addToWatchlist(payload: CryptoWatchlistItemRequest, userId: UUID, on db: any Database) async throws -> CryptoWatchlistItemResponse
    func updateWatchlistItem(id: UUID, payload: CryptoWatchlistItemRequest, userId: UUID, on db: any Database) async throws -> CryptoWatchlistItemResponse
    func removeFromWatchlist(id: UUID, userId: UUID, on db: any Database) async throws

    // Market data
    func cryptocurrencyList(on req: Request) async throws -> [CryptoAssetResponse]
    func quote(symbols: String, on req: Request) async throws -> [CryptoQuoteResponse]
    func quoteShort(symbol: String, on req: Request) async throws -> [CryptoQuoteShortResponse]
    func batchQuotes(short: Bool, on req: Request) async throws -> [CryptoQuoteShortResponse]
    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalLightPoint]
    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalFullPoint]
    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
    func fetchCryptoNews(symbol: String?, page: Int?, limit: Int?, from: String?, to: String?, on req: Request) async throws -> [FMPMarketNewsItem]
}

final class DefaultCryptoService: CryptoService {
    let provider: any CryptoDataProvider

    init(provider: any CryptoDataProvider) {
        self.provider = provider
    }

    // MARK: - Portfolio CRUD

    func listPortfolio(userId: UUID, on db: any Database) async throws -> [CryptoPortfolioItemResponse] {
        let items = try await CryptoPortfolioItem.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .all()
        return try items.map { try makeResponse(from: $0) }
    }

    func addToPortfolio(
        payload: CryptoPortfolioItemRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> CryptoPortfolioItemResponse {
        let symbol = normalizeSymbol(payload.symbol)

        // Check if the user already has this symbol — merge if so
        if let existing = try await CryptoPortfolioItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$symbol == symbol)
            .first()
        {
            let oldCost = existing.quantity * existing.averageBuyPrice
            let newCost = payload.quantity * payload.averageBuyPrice
            let totalQuantity = existing.quantity + payload.quantity

            existing.quantity = totalQuantity
            existing.averageBuyPrice = totalQuantity != 0 ? (oldCost + newCost) / totalQuantity : 0
            existing.name = payload.name
            try await existing.save(on: db)
            return try makeResponse(from: existing)
        }

        let item = CryptoPortfolioItem(
            userId: userId,
            symbol: symbol,
            name: payload.name.trimmingCharacters(in: .whitespacesAndNewlines),
            quantity: payload.quantity,
            averageBuyPrice: payload.averageBuyPrice
        )
        try await item.save(on: db)
        return try makeResponse(from: item)
    }

    func updatePortfolioItem(
        id: UUID,
        payload: CryptoPortfolioItemRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> CryptoPortfolioItemResponse {
        guard let item = try await CryptoPortfolioItem.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Crypto portfolio item not found.")
        }

        item.symbol = normalizeSymbol(payload.symbol)
        item.name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.quantity = payload.quantity
        item.averageBuyPrice = payload.averageBuyPrice
        try await item.save(on: db)
        return try makeResponse(from: item)
    }

    func removeFromPortfolio(id: UUID, userId: UUID, on db: any Database) async throws {
        guard let item = try await CryptoPortfolioItem.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Crypto portfolio item not found.")
        }
        try await item.delete(on: db)
    }

    // MARK: - Watchlist CRUD

    func listWatchlist(userId: UUID, on db: any Database) async throws -> [CryptoWatchlistItemResponse] {
        let items = try await CryptoWatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .all()
        return try items.map { try makeWatchlistResponse(from: $0) }
    }

    func addToWatchlist(
        payload: CryptoWatchlistItemRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> CryptoWatchlistItemResponse {
        let symbol = normalizeSymbol(payload.symbol)

        // Idempotent on (user, symbol): update the existing row instead of duplicating.
        if let existing = try await CryptoWatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$symbol == symbol)
            .first()
        {
            existing.name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.note = payload.note
            if let status = payload.status {
                existing.status = status.rawValue
            }
            try await existing.save(on: db)
            return try makeWatchlistResponse(from: existing)
        }

        let item = CryptoWatchlistItem(
            userId: userId,
            symbol: symbol,
            name: payload.name.trimmingCharacters(in: .whitespacesAndNewlines),
            note: payload.note,
            status: payload.status ?? .active
        )
        try await item.save(on: db)
        return try makeWatchlistResponse(from: item)
    }

    func updateWatchlistItem(
        id: UUID,
        payload: CryptoWatchlistItemRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> CryptoWatchlistItemResponse {
        guard let item = try await CryptoWatchlistItem.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Crypto watchlist item not found.")
        }

        item.symbol = normalizeSymbol(payload.symbol)
        item.name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.note = payload.note
        if let status = payload.status {
            item.status = status.rawValue
        }
        try await item.save(on: db)
        return try makeWatchlistResponse(from: item)
    }

    func removeFromWatchlist(id: UUID, userId: UUID, on db: any Database) async throws {
        guard let item = try await CryptoWatchlistItem.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Crypto watchlist item not found.")
        }
        try await item.delete(on: db)
    }

    // MARK: - Market Data Pass-through

    func cryptocurrencyList(on req: Request) async throws -> [CryptoAssetResponse] {
        try await provider.cryptocurrencyList(on: req)
    }

    func quote(symbols: String, on req: Request) async throws -> [CryptoQuoteResponse] {
        try await provider.quote(symbols: symbols, on: req)
    }

    func quoteShort(symbol: String, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        try await provider.quoteShort(symbol: symbol, on: req)
    }

    func batchQuotes(short: Bool, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        try await provider.batchQuotes(short: short, on: req)
    }

    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalLightPoint] {
        try await provider.historicalLight(symbol: symbol, from: from, to: to, on: req)
    }

    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalFullPoint] {
        try await provider.historicalFull(symbol: symbol, from: from, to: to, on: req)
    }

    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        try await provider.intraday1min(symbol: symbol, from: from, to: to, on: req)
    }

    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        try await provider.intraday5min(symbol: symbol, from: from, to: to, on: req)
    }

    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        try await provider.intraday1hour(symbol: symbol, from: from, to: to, on: req)
    }

    func fetchCryptoNews(symbol: String?, page: Int?, limit: Int?, from: String?, to: String?, on req: Request) async throws -> [FMPMarketNewsItem] {
        try await provider.fetchCryptoNews(symbol: symbol, page: page, limit: limit, from: from, to: to, on: req)
    }

    // MARK: - Private Helpers

    private func normalizeSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func makeResponse(from model: CryptoPortfolioItem) throws -> CryptoPortfolioItemResponse {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Crypto portfolio item id missing.")
        }
        return CryptoPortfolioItemResponse(
            id: id.uuidString,
            symbol: model.symbol,
            name: model.name,
            quantity: model.quantity,
            averageBuyPrice: model.averageBuyPrice,
            createdAt: formatISODateTime(model.createdAt),
            updatedAt: formatISODateTime(model.updatedAt)
        )
    }

    private func makeWatchlistResponse(from model: CryptoWatchlistItem) throws -> CryptoWatchlistItemResponse {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Crypto watchlist item id missing.")
        }
        return CryptoWatchlistItemResponse(
            id: id.uuidString,
            symbol: model.symbol,
            name: model.name,
            note: model.note,
            status: WatchlistStatus(rawValue: model.status) ?? .active,
            createdAt: formatISODateTime(model.createdAt),
            updatedAt: formatISODateTime(model.updatedAt)
        )
    }

    private func formatISODateTime(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
