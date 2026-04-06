import Fluent
import Foundation
import Vapor

enum StockServiceError: Error {
    case notFound
    case invalidSymbol
    case valuationNotFound
    case valuationAlreadyExists
}

extension StockServiceError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .notFound:
            return .notFound
        case .invalidSymbol:
            return .badRequest
        case .valuationNotFound:
            return .notFound
        case .valuationAlreadyExists:
            return .conflict
        }
    }

    var reason: String {
        switch self {
        case .notFound:
            return "Stock not found."
        case .invalidSymbol:
            return "Invalid stock symbol."
        case .valuationNotFound:
            return "Stock valuation not found."
        case .valuationAlreadyExists:
            return "Stock valuation already exists."
        }
    }
}

protocol StockService: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [StockResponse]
    func get(id: UUID, userId: UUID, on db: any Database) async throws -> StockResponse
    func get(symbol: String, userId: UUID, on db: any Database) async throws -> StockResponse
    func getValuation(symbol: String, userId: UUID, on db: any Database) async throws
        -> StockValuationRequest
    func create(payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    func createValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuationRequest
    func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws
        -> BulkStockResponse
    func update(id: UUID, payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    func updateValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuationRequest
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

    func getValuation(symbol: String, userId: UUID, on db: any Database) async throws
        -> StockValuationRequest
    {
        let normalizedSymbol = try validateSymbol(symbol)
        guard try await repo.find(symbol: normalizedSymbol, userId: userId, on: db) != nil else {
            throw StockServiceError.notFound
        }
        guard let valuation = try await repo.findValuation(symbol: normalizedSymbol, userId: userId, on: db)
        else {
            throw StockServiceError.valuationNotFound
        }
        return StockValuationRequest(from: valuation)
    }

    func create(payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    {
        _ = try validateSymbol(payload.symbol)
        let stock = try await repo.create(payload: payload, userId: userId, on: db)
        return try StockResponse(from: stock)
    }

    func createValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuationRequest {
        let normalizedPayload = try normalizeValuationPayload(pathSymbol: symbol, payload: payload)
        guard try await repo.find(symbol: normalizedPayload.symbol, userId: userId, on: db) != nil else {
            throw StockServiceError.notFound
        }
        if try await repo.findValuation(symbol: normalizedPayload.symbol, userId: userId, on: db) != nil {
            throw StockServiceError.valuationAlreadyExists
        }

        let valuation = try await repo.createValuation(
            payload: normalizedPayload,
            userId: userId,
            on: db
        )
        return StockValuationRequest(from: valuation)
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
        _ = try validateSymbol(payload.symbol)
        guard let stock = try await repo.update(id: id, payload: payload, userId: userId, on: db)
        else {
            throw StockServiceError.notFound
        }
        return try StockResponse(from: stock)
    }

    func updateValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuationRequest {
        let normalizedPayload = try normalizeValuationPayload(pathSymbol: symbol, payload: payload)
        guard try await repo.find(symbol: normalizedPayload.symbol, userId: userId, on: db) != nil else {
            throw StockServiceError.notFound
        }
        guard
            let valuation = try await repo.updateValuation(
                symbol: normalizedPayload.symbol,
                payload: normalizedPayload,
                userId: userId,
                on: db
            )
        else {
            throw StockServiceError.valuationNotFound
        }
        return StockValuationRequest(from: valuation)
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws {
        let deleted = try await repo.delete(id: id, userId: userId, on: db)
        guard deleted else {
            throw StockServiceError.notFound
        }
    }

    private func validateSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw StockServiceError.invalidSymbol
        }
        return normalized.uppercased()
    }

    private func normalizeValuationPayload(pathSymbol: String, payload: StockValuationRequest) throws
        -> StockValuationRequest
    {
        let normalizedPathSymbol = try validateSymbol(pathSymbol)
        let normalizedBodySymbol = try validateSymbol(payload.symbol)
        guard normalizedPathSymbol == normalizedBodySymbol else {
            throw Abort(
                .badRequest,
                reason:
                    """
                    Body symbol must match the route symbol. \
                    routeRaw=\(String(reflecting: pathSymbol)) \
                    bodyRaw=\(String(reflecting: payload.symbol)) \
                    routeNormalized=\(String(reflecting: normalizedPathSymbol)) \
                    bodyNormalized=\(String(reflecting: normalizedBodySymbol))
                    """
            )
        }

        return StockValuationRequest(
            symbol: normalizedPathSymbol,
            bearCase: try normalizePriceRange(payload.bearCase, field: "bearCase"),
            baseCase: try normalizePriceRange(payload.baseCase, field: "baseCase"),
            bullCase: try normalizePriceRange(payload.bullCase, field: "bullCase"),
            rationale: normalizeOptionalText(payload.rationale),
            targetDate: try normalizeOptionalDateString(payload.targetDate)
        )
    }

    private func normalizePriceRange(_ range: PriceRange, field: String) throws -> PriceRange {
        guard range.low >= 0 else {
            throw Abort(.badRequest, reason: "\(field).low must be greater than or equal to 0.")
        }
        guard range.high >= 0 else {
            throw Abort(.badRequest, reason: "\(field).high must be greater than or equal to 0.")
        }
        guard range.low <= range.high else {
            throw Abort(.badRequest, reason: "\(field).low must be less than or equal to \(field).high.")
        }
        return range
    }

    private func normalizeOptionalText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeOptionalDateString(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"

        guard let value = formatter.date(from: trimmed) else {
            throw Abort(.badRequest, reason: "Invalid targetDate. Expected YYYY-MM-DD.")
        }
        return formatter.string(from: value)
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
            notes: model.notes,
            category: model.category
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

extension StockValuationRequest {
    init(from model: StockValuation) {
        self.init(
            symbol: model.symbol,
            bearCase: PriceRange(low: model.bearLow, high: model.bearHigh),
            baseCase: PriceRange(low: model.baseLow, high: model.baseHigh),
            bullCase: PriceRange(low: model.bullLow, high: model.bullHigh),
            rationale: model.rationale,
            targetDate: Self.formatISODateOnly(model.targetDate)
        )
    }

    private static func formatISODateOnly(_ date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
