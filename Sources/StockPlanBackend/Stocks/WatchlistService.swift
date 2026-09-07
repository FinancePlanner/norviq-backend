import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Watchlist writes, owned in one place.
///
/// This logic previously lived inline in StockController+Watchlist, which meant
/// the only way to reach it was an HTTP request carrying a session or a scoped
/// token. The assistant (and therefore Telegram) runs in-process and cannot make
/// that request as the user, so it had no way to touch the watchlist at all.
///
/// The upsert semantics are load-bearing and easy to lose in a re-implementation:
/// an existing (user, list, symbol) is patched rather than duplicated, and a row
/// that had been archived is revived to active when no explicit status is given —
/// re-adding a symbol you previously archived should bring it back, not fail.
struct WatchlistService {
    struct UpsertResult {
        let item: WatchlistItem
        /// False when an existing row was patched, so callers can answer 200 vs 201.
        let created: Bool
    }

    let req: Request

    func upsert(
        payload: WatchlistItemRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> UpsertResult {
        let symbol = try Self.normalizeSymbol(payload.symbol)
        let note = Self.emptyToNil(payload.note)
        let nextReviewAt = try Self.parseISODateOnly(payload.nextReviewAt, field: "nextReviewAt")
        guard let targetListId = try await resolveWatchlistListId(
            requestedId: payload.watchlistListId,
            userId: userId,
            on: db,
            defaultWhenMissing: true
        ) else {
            throw Abort(.internalServerError, reason: "Failed to resolve watchlist list.")
        }

        if let existing = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$watchlistListId == targetListId)
            .filter(\.$symbol == symbol)
            .first()
        {
            var didChange = false

            if let rawNote = payload.note {
                let normalizedNote = Self.emptyToNil(rawNote)
                if existing.note != normalizedNote {
                    existing.note = normalizedNote
                    didChange = true
                }
            }

            if let status = payload.status {
                let normalizedStatus = status.rawValue
                if existing.status != normalizedStatus {
                    existing.status = normalizedStatus
                    didChange = true
                }
            } else if existing.status == WatchlistStatus.archived.rawValue {
                existing.status = WatchlistStatus.active.rawValue
                didChange = true
            }

            if payload.nextReviewAt != nil, existing.nextReviewAt != nextReviewAt {
                existing.nextReviewAt = nextReviewAt
                didChange = true
            }

            if didChange {
                try await existing.save(on: db)
            }
            return UpsertResult(item: existing, created: false)
        }

        let currentCount = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .count()
        try await req.usageCounterService.enforceResourceLimit(
            .watchlistItems,
            userId: userId,
            currentCount: currentCount,
            adding: 1,
            on: db
        )

        let item = WatchlistItem(
            userId: userId,
            watchlistListId: targetListId,
            symbol: symbol,
            note: note,
            status: payload.status ?? .active,
            nextReviewAt: nextReviewAt
        )
        try await item.save(on: db)
        try? await req.usageCounterService.syncResourceCount(
            .watchlistItems,
            userId: userId,
            count: currentCount + 1,
            on: db
        )
        return UpsertResult(item: item, created: true)
    }

    func list(userId: UUID, on db: any Database) async throws -> [WatchlistItem] {
        try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$symbol)
            .all()
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws {
        guard let item = try await WatchlistItem.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Watchlist entry not found.")
        }
        try await item.delete(on: db)
    }

    // MARK: - Normalisation

    static func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return normalized
    }

    static func emptyToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseISODateOnly(_ raw: String?, field: String) throws -> Date? {
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

    static func isoDateOnly(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func response(from model: WatchlistItem) -> WatchlistItemResponse {
        let id = model.id ?? UUID()
        let status = WatchlistStatus(rawValue: model.status) ?? .active
        return WatchlistItemResponse(
            id: id.uuidString,
            symbol: model.symbol,
            note: model.note,
            status: status,
            createdAt: formatISODateTime(model.createdAt),
            updatedAt: formatISODateTime(model.updatedAt),
            lastReviewedAt: isoDateOnly(model.lastReviewedAt),
            nextReviewAt: isoDateOnly(model.nextReviewAt),
            watchlistListId: model.watchlistListId.uuidString
        )
    }
}
