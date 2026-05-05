import Fluent
import Foundation
import Vapor

struct StockListCursor {
    let createdAt: Date
    let id: UUID?

    static func parse(_ raw: String?) -> StockListCursor? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let decoded = decodeOpaqueCursor(raw) {
            return decoded
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) else {
            return nil
        }
        return StockListCursor(createdAt: date, id: nil)
    }

    static func encode(createdAt: Date, id: UUID) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = "\(formatter.string(from: createdAt))|\(id.uuidString)"
        return Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeOpaqueCursor(_ raw: String) -> StockListCursor? {
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }

        guard let data = Data(base64Encoded: base64),
              let payload = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let createdAt = formatter.date(from: parts[0]),
              let id = UUID(uuidString: parts[1])
        else {
            return nil
        }
        return StockListCursor(createdAt: createdAt, id: id)
    }
}

func ensureDefaultPortfolioListId(userId: UUID, on db: any Database) async throws -> UUID {
    if let existing = try await PortfolioList.query(on: db)
        .filter(\.$userId == userId)
        .filter(\.$isDefault == true)
        .first(),
        let id = existing.id
    {
        return id
    }

    if let fallback = try await PortfolioList.query(on: db)
        .filter(\.$userId == userId)
        .sort(\.$createdAt, .ascending)
        .first(),
        let fallbackId = fallback.id
    {
        fallback.isDefault = true
        try await fallback.save(on: db)
        return fallbackId
    }

    let created = PortfolioList(userId: userId, name: "Main Portfolio", isDefault: true)
    try await created.save(on: db)
    guard let id = created.id else {
        throw Abort(.internalServerError, reason: "Failed to create default portfolio list.")
    }
    return id
}

func ensureDefaultWatchlistListId(userId: UUID, on db: any Database) async throws -> UUID {
    if let existing = try await WatchlistList.query(on: db)
        .filter(\.$userId == userId)
        .filter(\.$isDefault == true)
        .first(),
        let id = existing.id
    {
        return id
    }

    if let fallback = try await WatchlistList.query(on: db)
        .filter(\.$userId == userId)
        .sort(\.$createdAt, .ascending)
        .first(),
        let fallbackId = fallback.id
    {
        fallback.isDefault = true
        try await fallback.save(on: db)
        return fallbackId
    }

    let created = WatchlistList(userId: userId, name: "Main Watchlist", isDefault: true)
    try await created.save(on: db)
    guard let id = created.id else {
        throw Abort(.internalServerError, reason: "Failed to create default watchlist list.")
    }
    return id
}

func resolvePortfolioListId(
    requestedId: String?,
    userId: UUID,
    on db: any Database,
    defaultWhenMissing: Bool = true
) async throws -> UUID? {
    guard let raw = requestedId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return defaultWhenMissing ? try await ensureDefaultPortfolioListId(userId: userId, on: db) : nil
    }

    guard let listId = UUID(uuidString: raw) else {
        throw Abort(.badRequest, reason: "Invalid portfolioListId.")
    }

    let exists = try await PortfolioList.query(on: db)
        .filter(\.$id == listId)
        .filter(\.$userId == userId)
        .first()
    guard exists != nil else {
        throw Abort(.notFound, reason: "Portfolio list not found.")
    }
    return listId
}

func resolveWatchlistListId(
    requestedId: String?,
    userId: UUID,
    on db: any Database,
    defaultWhenMissing: Bool = true
) async throws -> UUID? {
    guard let raw = requestedId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return defaultWhenMissing ? try await ensureDefaultWatchlistListId(userId: userId, on: db) : nil
    }

    guard let listId = UUID(uuidString: raw) else {
        throw Abort(.badRequest, reason: "Invalid watchlistListId.")
    }

    let exists = try await WatchlistList.query(on: db)
        .filter(\.$id == listId)
        .filter(\.$userId == userId)
        .first()
    guard exists != nil else {
        throw Abort(.notFound, reason: "Watchlist list not found.")
    }
    return listId
}

func normalizeListName(_ raw: String, field: String = "name") throws -> String {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
        throw Abort(.badRequest, reason: "\(field) is required.")
    }
    guard normalized.count <= 80 else {
        throw Abort(.badRequest, reason: "\(field) must be at most 80 characters.")
    }
    return normalized
}

func formatISODateTime(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
