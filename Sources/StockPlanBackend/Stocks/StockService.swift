import Fluent
import Foundation
import Vapor

enum StockServiceError: Error {
    case notFound
    case invalidSymbol
}

extension StockServiceError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .notFound:
            return .notFound
        case .invalidSymbol:
            return .badRequest
        }
    }

    var reason: String {
        switch self {
        case .notFound:
            return "Stock not found."
        case .invalidSymbol:
            return "Invalid stock symbol."
        }
    }
}

protocol StockService: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [StockResponse]
    func get(id: UUID, userId: UUID, on db: any Database) async throws -> StockResponse
    func get(symbol: String, userId: UUID, on db: any Database) async throws -> StockResponse
    func create(payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws
        -> BulkStockResponse
    func update(id: UUID, payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    func delete(id: UUID, userId: UUID, on db: any Database) async throws
}

struct StockServiceImpl: StockService {
    let repo: any StocksRepository

    func list(userId: UUID, on db: any Database) async throws -> [StockResponse] {
        let stocks = try await repo.list(userId: userId, on: db)
        return try stocks.map { try StockResponse(from: $0) }
    }

    func get(id: UUID, userId: UUID, on db: any Database) async throws -> StockResponse {
        guard let stock = try await repo.find(id: id, userId: userId, on: db) else {
            throw StockServiceError.notFound
        }
        return try StockResponse(from: stock)
    }

    func get(symbol: String, userId: UUID, on db: any Database) async throws -> StockResponse {
        guard let stock = try await repo.find(symbol: symbol, userId: userId, on: db) else {
            throw StockServiceError.notFound
        }
        return try StockResponse(from: stock)
    }

    func create(payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    {
        try validateSymbol(payload.symbol)
        let stock = try await repo.create(payload: payload, userId: userId, on: db)
        return try StockResponse(from: stock)
    }

    func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws
        -> BulkStockResponse
    {
        let results = try await repo.bulkCreate(payloads: payloads, userId: userId, on: db)
        let created = results.filter { $0.stock != nil }.count
        let failed = results.filter { $0.error != nil }.count
        return BulkStockResponse(created: created, failed: failed, results: results)
    }

    func update(id: UUID, payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    {
        try validateSymbol(payload.symbol)
        guard let stock = try await repo.update(id: id, payload: payload, userId: userId, on: db)
        else {
            throw StockServiceError.notFound
        }
        return try StockResponse(from: stock)
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws {
        let deleted = try await repo.delete(id: id, userId: userId, on: db)
        guard deleted else {
            throw StockServiceError.notFound
        }
    }

    private func validateSymbol(_ raw: String) throws {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw StockServiceError.invalidSymbol
        }
    }
}

extension StockResponse {
    init(from model: Stock) throws {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Stock id missing")
        }

        self.init(
            id: id.uuidString,
            symbol: model.symbol,
            shares: model.shares,
            buyPrice: model.buyPrice,
            buyDate: Self.formatISODateOnly(model.buyDate),
            notes: model.notes
        )
    }

    private static func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
