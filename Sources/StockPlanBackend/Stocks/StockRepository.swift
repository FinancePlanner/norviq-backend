import Fluent
import Foundation
import Vapor

protocol StocksRepository: Sendable {
    func list(userId: UUID, portfolioListId: UUID?, limit: Int, cursor: Date?, on db: any Database) async throws -> [Stock]
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

extension StocksRepository {
    func list(userId: UUID, on db: any Database) async throws -> [Stock] {
        try await list(userId: userId, portfolioListId: nil, limit: 100, cursor: nil, on: db)
    }

    func list(userId: UUID, portfolioListId: UUID?, on db: any Database) async throws -> [Stock] {
        try await list(userId: userId, portfolioListId: portfolioListId, limit: 100, cursor: nil, on: db)
    }
}

struct DatabaseStocksRepository: StocksRepository {
    func list(userId: UUID, portfolioListId: UUID? = nil, limit: Int, cursor: Date?, on db: any Database) async throws -> [Stock] {
        var query = Stock.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
        if let portfolioListId {
            query.filter(\.$portfolioListId == portfolioListId)
        }
        if let cursor {
            // Keyset: fetch records created before cursor
            query.filter(\.$createdAt < cursor)
        }
        query.limit(limit)
        return try await query.all()
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
        let normalizedSymbol = normalizeSymbol(payload.symbol)
        let targetListId = try await resolveRequestedPortfolioListId(
            payload.portfolioListId,
            userId: userId,
            on: db
        )

        let existingStocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId == targetListId)
            .filter(\.$symbol == normalizedSymbol)
            .all()

        if !existingStocks.isEmpty {
            // Merge duplicate holdings by symbol:
            // - shares add up
            // - buyPrice becomes a weighted average cost basis
            // - buyDate keeps the earliest cost-basis date
            // - notes: update only if payload includes new notes
            let sortedByEarliestDate = existingStocks.sorted { $0.buyDate < $1.buyDate }
            let primary = sortedByEarliestDate[0]

            let oldShares = sortedByEarliestDate.reduce(0) { $0 + $1.shares }
            let oldCostBasis = sortedByEarliestDate.reduce(0) { $0 + ($1.shares * $1.buyPrice) }

            let newShares = oldShares + payload.shares
            let newCostBasis = oldCostBasis + (payload.shares * payload.buyPrice)

            primary.shares = newShares
            primary.buyPrice = newShares != 0 ? newCostBasis / newShares : 0

            if buyDate < primary.buyDate {
                primary.buyDate = buyDate
            }

            if let payloadNotes = payload.notes {
                primary.notes = payloadNotes
            }

            primary.category = payload.category

            try await primary.save(on: db)

            // Delete extra duplicates so subsequent creates don't keep multiple rows.
            for extra in sortedByEarliestDate.dropFirst() {
                try await extra.delete(on: db)
            }

            return primary
        }

        let stock = Stock(
            userId: userId,
            portfolioListId: targetListId,
            symbol: normalizedSymbol,
            shares: payload.shares,
            buyPrice: payload.buyPrice,
            buyDate: buyDate,
            notes: payload.notes,
            category: payload.category
        )
        try await stock.save(on: db)
        return stock
    }

    func createValuation(payload: StockValuationRequest, userId: UUID, on db: any Database)
        async throws -> StockValuation
    {
        let valuation = try StockValuation(
            userId: userId,
            symbol: normalizeSymbol(payload.symbol),
            bearLow: payload.bearCase.low,
            bearHigh: payload.bearCase.high,
            baseLow: payload.baseCase.low,
            baseHigh: payload.baseCase.high,
            bullLow: payload.bullCase.low,
            bullHigh: payload.bullCase.high,
            rationale: emptyToNil(payload.rationale),
            targetDate: parseOptionalISODateOnly(payload.targetDate, field: "targetDate")
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
        let targetListId = try await resolveRequestedPortfolioListId(
            payload.portfolioListId,
            userId: userId,
            on: db
        )
        let normalizedSymbol = normalizeSymbol(payload.symbol)
        let buyDate = try parseISODateOnly(payload.buyDate)

        if let stockId = stock.id,
           let duplicate = try await Stock.query(on: db)
           .filter(\.$userId == userId)
           .filter(\.$portfolioListId == targetListId)
           .filter(\.$symbol == normalizedSymbol)
           .filter(\.$id != stockId)
           .first()
        {
            let mergedShares = duplicate.shares + payload.shares
            let mergedCostBasis = (duplicate.shares * duplicate.buyPrice) + (payload.shares * payload.buyPrice)

            duplicate.shares = mergedShares
            duplicate.buyPrice = mergedShares != 0 ? mergedCostBasis / mergedShares : 0
            duplicate.buyDate = min(duplicate.buyDate, buyDate)
            if payload.notes != nil {
                duplicate.notes = payload.notes
            }
            duplicate.category = payload.category
            duplicate.portfolioListId = targetListId
            try await duplicate.save(on: db)
            try await stock.delete(on: db)
            return duplicate
        }

        stock.symbol = normalizedSymbol
        stock.shares = payload.shares
        stock.buyPrice = payload.buyPrice
        stock.buyDate = buyDate
        stock.notes = payload.notes
        stock.category = payload.category
        stock.portfolioListId = targetListId
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

    private func resolveRequestedPortfolioListId(
        _ rawListId: String?,
        userId: UUID,
        on db: any Database
    ) async throws -> UUID {
        guard let listId = try await resolvePortfolioListId(
            requestedId: rawListId,
            userId: userId,
            on: db,
            defaultWhenMissing: true
        ) else {
            throw Abort(.internalServerError, reason: "Failed to resolve portfolio list.")
        }
        return listId
    }
}
