import Fluent
import Foundation
import Vapor

protocol StocksRepository: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [Stock]
    func find(id: UUID, userId: UUID, on db: any Database) async throws -> Stock?
    func find(symbol: String, userId: UUID, on db: any Database) async throws -> Stock?
    func findValuation(symbol: String, userId: UUID, on db: any Database) async throws
        -> StockValuation?
    func create(payload: StockRequest, userId: UUID, on db: any Database) async throws -> Stock
    func createValuation(payload: StockValuationRequest, userId: UUID, on db: any Database)
        async throws -> StockValuation
    func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws
        -> [BulkStockResultItem]
    func update(id: UUID, payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> Stock?
    func updateValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuation?
    func delete(id: UUID, userId: UUID, on db: any Database) async throws -> Bool
}

struct DatabaseStocksRepository: StocksRepository {
    func list(userId: UUID, on db: any Database) async throws -> [Stock] {
        try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .all()
    }

    func find(id: UUID, userId: UUID, on db: any Database) async throws -> Stock? {
        try await Stock.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
    }

    func find(symbol: String, userId: UUID, on db: any Database) async throws -> Stock? {
        let normalizedSymbol = normalizeSymbol(symbol)
        return try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$symbol == normalizedSymbol)
            .first()
    }

    func findValuation(symbol: String, userId: UUID, on db: any Database) async throws
        -> StockValuation?
    {
        let normalizedSymbol = normalizeSymbol(symbol)
        return try await StockValuation.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$symbol == normalizedSymbol)
            .first()
    }

    func create(payload: StockRequest, userId: UUID, on db: any Database) async throws -> Stock {
        let buyDate = try parseISODateOnly(payload.buyDate)
        let stock = Stock(
            userId: userId,
            symbol: normalizeSymbol(payload.symbol),
            shares: payload.shares,
            buyPrice: payload.buyPrice,
            buyDate: buyDate,
            notes: payload.notes
        )
        try await stock.save(on: db)
        return stock
    }

    func createValuation(payload: StockValuationRequest, userId: UUID, on db: any Database)
        async throws -> StockValuation
    {
        let valuation = StockValuation(
            userId: userId,
            symbol: normalizeSymbol(payload.symbol),
            bearLow: payload.bearCase.low,
            bearHigh: payload.bearCase.high,
            baseLow: payload.baseCase.low,
            baseHigh: payload.baseCase.high,
            bullLow: payload.bullCase.low,
            bullHigh: payload.bullCase.high,
            rationale: emptyToNil(payload.rationale),
            targetDate: try parseOptionalISODateOnly(payload.targetDate, field: "targetDate")
        )
        try await valuation.save(on: db)
        return valuation
    }

    func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws
        -> [BulkStockResultItem]
    {
        var results: [BulkStockResultItem] = []
        for (index, payload) in payloads.enumerated() {
            do {
                let stock = try await create(payload: payload, userId: userId, on: db)
                let response = try StockResponse(from: stock)
                results.append(BulkStockResultItem(index: index, stock: response))
            } catch {
                results.append(BulkStockResultItem(index: index, error: error.localizedDescription))
            }
        }
        return results
    }

    func update(id: UUID, payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> Stock?
    {
        guard let stock = try await find(id: id, userId: userId, on: db) else {
            return nil
        }
        stock.symbol = normalizeSymbol(payload.symbol)
        stock.shares = payload.shares
        stock.buyPrice = payload.buyPrice
        stock.buyDate = try parseISODateOnly(payload.buyDate)
        stock.notes = payload.notes
        try await stock.save(on: db)
        return stock
    }

    func updateValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuation? {
        guard let valuation = try await findValuation(symbol: symbol, userId: userId, on: db) else {
            return nil
        }

        valuation.symbol = normalizeSymbol(payload.symbol)
        valuation.bearLow = payload.bearCase.low
        valuation.bearHigh = payload.bearCase.high
        valuation.baseLow = payload.baseCase.low
        valuation.baseHigh = payload.baseCase.high
        valuation.bullLow = payload.bullCase.low
        valuation.bullHigh = payload.bullCase.high
        valuation.rationale = emptyToNil(payload.rationale)
        valuation.targetDate = try parseOptionalISODateOnly(payload.targetDate, field: "targetDate")
        try await valuation.save(on: db)
        return valuation
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws -> Bool {
        guard let stock = try await find(id: id, userId: userId, on: db) else {
            return false
        }
        try await stock.delete(on: db)
        return true
    }

    private func parseISODateOnly(_ raw: String) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Invalid buyDate. Expected YYYY-MM-DD.")
        }

        let parts = trimmed.split(separator: "-")
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else {
            throw Abort(.badRequest, reason: "Invalid buyDate. Expected YYYY-MM-DD.")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(year: year, month: month, day: day)

        guard let date = calendar.date(from: components) else {
            throw Abort(.badRequest, reason: "Invalid buyDate. Expected YYYY-MM-DD.")
        }
        return date
    }

    private func parseOptionalISODateOnly(_ raw: String?, field: String) throws -> Date? {
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
            throw Abort(.badRequest, reason: "Invalid \(field). Expected YYYY-MM-DD.")
        }
        return value
    }

    private func normalizeSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func emptyToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
