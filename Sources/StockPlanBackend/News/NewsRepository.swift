import Fluent
import Foundation

protocol NewsRepository: Sendable {
    func list(userId: UUID, symbol: String?, limit: Int?, on db: any Database) async throws -> [NewsItem]
    func listFeed(userId: UUID, trackedSymbols: [String], limit: Int, on db: any Database) async throws -> [NewsItem]
    func find(id: UUID, userId: UUID, on db: any Database) async throws -> NewsItem?
    func save(_ item: NewsItem, on db: any Database) async throws
    func delete(_ item: NewsItem, on db: any Database) async throws
    func trackedSymbols(userId: UUID, on db: any Database) async throws -> [String]
}

struct DatabaseNewsRepository: NewsRepository {
    func list(userId: UUID, symbol: String?, limit: Int?, on db: any Database) async throws -> [NewsItem] {
        let query = NewsItem.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$publishedAt, .descending)
            .sort(\.$createdAt, .descending)

        if let symbol, !symbol.isEmpty {
            query.filter(\.$symbol == symbol)
        }

        if let limit, limit > 0 {
            query.limit(limit)
        }

        return try await query.all()
    }

    func listFeed(userId: UUID, trackedSymbols: [String], limit: Int, on db: any Database) async throws -> [NewsItem] {
        guard !trackedSymbols.isEmpty else { return [] }

        let query = NewsItem.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$publishedAt, .descending)
            .sort(\.$createdAt, .descending)
            .limit(max(1, limit))

        query.group(.or) { group in
            for symbol in trackedSymbols {
                group.filter(\.$symbol == symbol)
            }
        }

        return try await query.all()
    }

    func find(id: UUID, userId: UUID, on db: any Database) async throws -> NewsItem? {
        try await NewsItem.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
    }

    func save(_ item: NewsItem, on db: any Database) async throws {
        try await item.save(on: db)
    }

    func delete(_ item: NewsItem, on db: any Database) async throws {
        try await item.delete(on: db)
    }

    func trackedSymbols(userId: UUID, on db: any Database) async throws -> [String] {
        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .all()
            .map(\.symbol)

        let watchlist = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$status != "archived")
            .all()
            .map(\.symbol)

        return Array(Set(stocks + watchlist))
    }
}
