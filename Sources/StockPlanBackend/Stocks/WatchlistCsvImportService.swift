import Fluent
import Foundation
import StockPlanShared
import Vapor

struct WatchlistCsvImportPreviewItem: Content, Equatable {
    let line: Int
    let symbol: String
    let note: String?
    let status: WatchlistStatus?
    let existingItemId: String?
    let willUpdateExisting: Bool
}

struct WatchlistCsvImportPreviewResponse: Content, Equatable {
    let watchlistListId: String
    let items: [WatchlistCsvImportPreviewItem]
    let errors: [CsvImportPreviewError]
}

struct WatchlistCsvImportCommitResponse: Content, Equatable {
    let watchlistListId: String
    let inserted: [WatchlistItemResponse]
    let updated: [WatchlistItemResponse]
    let errors: [CsvImportPreviewError]
}

struct WatchlistCsvImportService {
    func preview(
        csv: String,
        watchlistListId rawWatchlistListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> WatchlistCsvImportPreviewResponse {
        let targetListId = try await requireWatchlistListId(
            requestedId: rawWatchlistListId,
            userId: userId,
            on: req.db
        )
        let base = try CsvImportService().preview(csv: csv, provider: "watchlist")
        let existingItems = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$watchlistListId == targetListId)
            .all()
        let existingBySymbol: [String: WatchlistItem] = Dictionary(
            uniqueKeysWithValues: existingItems.map { ($0.symbol, $0) }
        )

        let errors = base.errors
        var items: [WatchlistCsvImportPreviewItem] = []
        items.reserveCapacity(base.items.count)

        for item in base.items {
            let existing = existingBySymbol[item.symbol]
            items.append(
                WatchlistCsvImportPreviewItem(
                    line: item.line,
                    symbol: item.symbol,
                    note: item.notes,
                    status: nil,
                    existingItemId: existing?.id?.uuidString,
                    willUpdateExisting: existing != nil
                )
            )
        }

        return .init(
            watchlistListId: targetListId.uuidString,
            items: items,
            errors: dedupeErrors(errors)
        )
    }

    func commit(
        csv: String,
        watchlistListId rawWatchlistListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> WatchlistCsvImportCommitResponse {
        let preview = try await preview(
            csv: csv,
            watchlistListId: rawWatchlistListId,
            userId: userId,
            on: req
        )
        guard let targetListId = UUID(uuidString: preview.watchlistListId) else {
            throw Abort(.internalServerError, reason: "Failed to resolve watchlist list.")
        }

        let invalidLines = Set(preview.errors.map(\.line))
        let validItems = preview.items.filter { !invalidLines.contains($0.line) }
        let groupedItems = Dictionary(grouping: validItems, by: { $0.symbol })
        let uniqueItems: [WatchlistCsvImportPreviewItem] = groupedItems.compactMap { _, rows in
            rows.sorted { $0.line < $1.line }.last
        }
        .sorted { $0.symbol < $1.symbol }

        let existingItems = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$watchlistListId == targetListId)
            .all()
        let existingBySymbol: [String: WatchlistItem] = Dictionary(
            uniqueKeysWithValues: existingItems.map { ($0.symbol, $0) }
        )
        let newItemCount = uniqueItems.count(where: { existingBySymbol[$0.symbol] == nil })

        if newItemCount > 0 {
            let currentCount = try await WatchlistItem.query(on: req.db)
                .filter(\.$userId == userId)
                .count()
            try await req.usageCounterService.enforceResourceLimit(
                .watchlistItems,
                userId: userId,
                currentCount: currentCount,
                adding: newItemCount,
                on: req.db
            )
        }

        var inserted: [WatchlistItemResponse] = []
        var updated: [WatchlistItemResponse] = []

        for item in uniqueItems {
            if let existing = existingBySymbol[item.symbol] {
                var didChange = false
                if let note = item.note, existing.note != note {
                    existing.note = note
                    didChange = true
                }
                if let status = item.status, existing.status != status.rawValue {
                    existing.status = status.rawValue
                    didChange = true
                } else if item.status == nil, existing.status == WatchlistStatus.archived.rawValue {
                    existing.status = WatchlistStatus.active.rawValue
                    didChange = true
                }
                if didChange {
                    try await existing.save(on: req.db)
                }
                updated.append(StockController().makeWatchlistItemResponse(from: existing))
                continue
            }

            let created = WatchlistItem(
                userId: userId,
                watchlistListId: targetListId,
                symbol: item.symbol,
                note: item.note,
                status: item.status ?? .active
            )
            try await created.save(on: req.db)
            inserted.append(StockController().makeWatchlistItemResponse(from: created))
        }

        if !uniqueItems.isEmpty {
            try await req.usageCounterService.incrementUsage(.csvImports, userId: userId, by: 1, on: req.db)
            let updatedCount = try await WatchlistItem.query(on: req.db)
                .filter(\.$userId == userId)
                .count()
            try? await req.usageCounterService.syncResourceCount(
                .watchlistItems,
                userId: userId,
                count: updatedCount,
                on: req.db
            )
        }

        return .init(
            watchlistListId: preview.watchlistListId,
            inserted: inserted,
            updated: updated,
            errors: preview.errors
        )
    }
}

private extension WatchlistCsvImportService {
    func requireWatchlistListId(requestedId: String?, userId: UUID, on db: any Database) async throws -> UUID {
        guard let listId = try await resolveWatchlistListId(
            requestedId: requestedId,
            userId: userId,
            on: db,
            defaultWhenMissing: true
        ) else {
            throw Abort(.internalServerError, reason: "Failed to resolve watchlist list.")
        }
        return listId
    }

    func dedupeErrors(_ errors: [CsvImportPreviewError]) -> [CsvImportPreviewError] {
        var seen = Set<String>()
        var result: [CsvImportPreviewError] = []
        for error in errors {
            let key = "\(error.line)|\(error.message)"
            if seen.insert(key).inserted {
                result.append(error)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.line == rhs.line {
                return lhs.message < rhs.message
            }
            return lhs.line < rhs.line
        }
    }
}
