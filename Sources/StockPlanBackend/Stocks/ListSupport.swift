import Fluent
import Foundation
import Vapor

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
