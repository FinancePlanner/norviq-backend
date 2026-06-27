import Fluent
import Foundation
import Vapor

extension StockController {
    private struct WatchlistItemsQuery: Content {
        let watchlistListId: String?
    }

    private struct WatchlistCsvQuery: Content {
        let watchlistListId: String?
    }

    private struct WatchlistCsvMultipartUpload: Content {
        var file: File?
        var csv: File?
    }

    @Sendable
    func listWatchlist(req: Request) async throws -> [WatchlistItemResponse] {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(WatchlistItemsQuery.self)
        guard let watchlistListId = try await resolveWatchlistListId(
            requestedId: query.watchlistListId,
            userId: session.userId,
            on: req.db,
            defaultWhenMissing: true
        ) else {
            throw Abort(.internalServerError, reason: "Failed to resolve watchlist list.")
        }

        let items = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$watchlistListId == watchlistListId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)
            .all()

        return items.map(makeWatchlistItemResponse)
    }

    @Sendable
    func importWatchlistCsvPreview(req: Request) async throws -> WatchlistCsvImportPreviewResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(WatchlistCsvQuery.self)
        let csv = try await readWatchlistCsvUpload(req)
        return try await WatchlistCsvImportService().preview(
            csv: csv,
            watchlistListId: query.watchlistListId,
            userId: session.userId,
            on: req
        )
    }

    @Sendable
    func importWatchlistCsvCommit(req: Request) async throws -> WatchlistCsvImportCommitResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(WatchlistCsvQuery.self)
        let csv = try await readWatchlistCsvUpload(req)
        let response = try await WatchlistCsvImportService().commit(
            csv: csv,
            watchlistListId: query.watchlistListId,
            userId: session.userId,
            on: req
        )
        await req.reconcileBadges(userId: session.userId, on: req.db)
        return response
    }

    @Sendable
    func createWatchlistItem(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(WatchlistItemRequest.self)
        let symbol = try normalizeSymbol(payload.symbol)
        let note = emptyToNil(payload.note)
        let nextReviewAt = try parseISODateOnly(payload.nextReviewAt, field: "nextReviewAt")
        guard let targetListId = try await resolveWatchlistListId(
            requestedId: payload.watchlistListId,
            userId: session.userId,
            on: req.db,
            defaultWhenMissing: true
        ) else {
            throw Abort(.internalServerError, reason: "Failed to resolve watchlist list.")
        }

        if let existing = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$watchlistListId == targetListId)
            .filter(\.$symbol == symbol)
            .first()
        {
            var didChange = false

            if let rawNote = payload.note {
                let normalizedNote = emptyToNil(rawNote)
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
                try await existing.save(on: req.db)
            }

            let res = Response(status: .ok)
            try res.content.encode(makeWatchlistItemResponse(from: existing))
            return res
        }

        let currentCount = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count()
        try await req.usageCounterService.enforceResourceLimit(
            .watchlistItems,
            userId: session.userId,
            currentCount: currentCount,
            adding: 1,
            on: req.db
        )

        let item = WatchlistItem(
            userId: session.userId,
            watchlistListId: targetListId,
            symbol: symbol,
            note: note,
            status: payload.status ?? .active,
            nextReviewAt: nextReviewAt
        )
        try await item.save(on: req.db)
        try? await req.usageCounterService.syncResourceCount(
            .watchlistItems,
            userId: session.userId,
            count: currentCount + 1,
            on: req.db
        )
        let res = Response(status: .created)
        try res.content.encode(makeWatchlistItemResponse(from: item))
        return res
    }

    @Sendable
    func updateWatchlistItem(req: Request) async throws -> WatchlistItemResponse {
        let session = try req.auth.require(SessionToken.self)
        let watchlistId = try requireUUIDParameter(
            req, name: "watchlistId", reason: "Invalid watchlist ID"
        )
        let payload = try req.content.decode(WatchlistItemUpdateRequest.self)

        guard
            let item = try await WatchlistItem.query(on: req.db)
            .filter(\.$id == watchlistId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Watchlist item not found.")
        }

        let targetListId = try await resolveWatchlistListId(
            requestedId: payload.watchlistListId,
            userId: session.userId,
            on: req.db,
            defaultWhenMissing: false
        ) ?? item.watchlistListId

        if targetListId != item.watchlistListId,
           let itemId = item.id,
           let duplicate = try await WatchlistItem.query(on: req.db)
           .filter(\.$userId == session.userId)
           .filter(\.$watchlistListId == targetListId)
           .filter(\.$symbol == item.symbol)
           .filter(\.$id != itemId)
           .first()
        {
            if let rawNote = payload.note {
                duplicate.note = emptyToNil(rawNote)
            }
            if let status = payload.status {
                duplicate.status = status.rawValue
            }
            if payload.lastReviewedAt != nil {
                duplicate.lastReviewedAt = try parseISODateOnly(
                    payload.lastReviewedAt,
                    field: "lastReviewedAt"
                )
            }
            if payload.nextReviewAt != nil {
                duplicate.nextReviewAt = try parseISODateOnly(
                    payload.nextReviewAt,
                    field: "nextReviewAt"
                )
            }
            try await duplicate.save(on: req.db)
            try await item.delete(on: req.db)
            return makeWatchlistItemResponse(from: duplicate)
        }

        var didChange = false
        if item.watchlistListId != targetListId {
            item.watchlistListId = targetListId
            didChange = true
        }

        if let rawNote = payload.note {
            let normalizedNote = emptyToNil(rawNote)
            if item.note != normalizedNote {
                item.note = normalizedNote
                didChange = true
            }
        }

        if let status = payload.status {
            let normalizedStatus = status.rawValue
            if item.status != normalizedStatus {
                item.status = normalizedStatus
                didChange = true
            }
        }

        if payload.lastReviewedAt != nil {
            let lastReviewedAt = try parseISODateOnly(payload.lastReviewedAt, field: "lastReviewedAt")
            if item.lastReviewedAt != lastReviewedAt {
                item.lastReviewedAt = lastReviewedAt
                didChange = true
            }
        }

        if payload.nextReviewAt != nil {
            let nextReviewAt = try parseISODateOnly(payload.nextReviewAt, field: "nextReviewAt")
            if item.nextReviewAt != nextReviewAt {
                item.nextReviewAt = nextReviewAt
                didChange = true
            }
        }

        if didChange {
            try await item.save(on: req.db)
        }

        return makeWatchlistItemResponse(from: item)
    }

    @Sendable
    func deleteWatchlistItem(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let watchlistId = try requireUUIDParameter(
            req, name: "watchlistId", reason: "Invalid watchlist ID"
        )

        guard
            let item = try await WatchlistItem.query(on: req.db)
            .filter(\.$id == watchlistId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Watchlist item not found.")
        }

        try await item.delete(on: req.db)
        let updatedCount = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count()
        try? await req.usageCounterService.syncResourceCount(
            .watchlistItems,
            userId: session.userId,
            count: updatedCount,
            on: req.db
        )
        return .noContent
    }

    @Sendable
    func listWatchlistLists(req: Request) async throws -> [WatchlistListResponse] {
        let session = try req.auth.require(SessionToken.self)

        if try await WatchlistList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count() == 0
        {
            _ = try await ensureDefaultWatchlistListId(userId: session.userId, on: req.db)
        }

        let lists = try await WatchlistList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$isDefault, .descending)
            .sort(\.$createdAt, .ascending)
            .all()

        return lists.map(makeWatchlistListResponse)
    }

    @Sendable
    func createWatchlistList(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(WatchlistListRequest.self)
        let name = try normalizeListName(payload.name)

        let list = WatchlistList(userId: session.userId, name: name, isDefault: false)
        try await list.save(on: req.db)

        let response = makeWatchlistListResponse(from: list)
        let res = Response(status: .created)
        try res.content.encode(response)
        return res
    }

    @Sendable
    func updateWatchlistList(req: Request) async throws -> WatchlistListResponse {
        let session = try req.auth.require(SessionToken.self)
        let listId = try requireUUIDParameter(
            req,
            name: "watchlistListId",
            reason: "Invalid watchlist list ID"
        )
        let payload = try req.content.decode(WatchlistListRequest.self)
        let name = try normalizeListName(payload.name)

        guard let list = try await WatchlistList.query(on: req.db)
            .filter(\.$id == listId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Watchlist list not found.")
        }

        list.name = name
        try await list.save(on: req.db)
        return makeWatchlistListResponse(from: list)
    }

    @Sendable
    func deleteWatchlistList(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let listId = try requireUUIDParameter(
            req,
            name: "watchlistListId",
            reason: "Invalid watchlist list ID"
        )

        try await req.db.transaction { tx in
            guard let list = try await WatchlistList.query(on: tx)
                .filter(\.$id == listId)
                .filter(\.$userId == session.userId)
                .first()
            else {
                throw Abort(.notFound, reason: "Watchlist list not found.")
            }

            if list.isDefault {
                throw Abort(.badRequest, reason: "Default watchlist list cannot be deleted.")
            }

            guard let defaultListId = try await resolveWatchlistListId(
                requestedId: nil,
                userId: session.userId,
                on: tx,
                defaultWhenMissing: true
            ) else {
                throw Abort(.internalServerError, reason: "Failed to resolve default watchlist list.")
            }

            let items = try await WatchlistItem.query(on: tx)
                .filter(\.$userId == session.userId)
                .filter(\.$watchlistListId == listId)
                .all()

            for item in items {
                if let itemId = item.id,
                   let duplicate = try await WatchlistItem.query(on: tx)
                   .filter(\.$userId == session.userId)
                   .filter(\.$watchlistListId == defaultListId)
                   .filter(\.$symbol == item.symbol)
                   .filter(\.$id != itemId)
                   .first()
                {
                    duplicate.note = duplicate.note ?? item.note
                    if duplicate.status == WatchlistStatus.archived.rawValue,
                       item.status != WatchlistStatus.archived.rawValue
                    {
                        duplicate.status = item.status
                    }
                    if duplicate.lastReviewedAt == nil {
                        duplicate.lastReviewedAt = item.lastReviewedAt
                    }
                    if duplicate.nextReviewAt == nil {
                        duplicate.nextReviewAt = item.nextReviewAt
                    }
                    try await duplicate.save(on: tx)
                    try await item.delete(on: tx)
                    continue
                }

                item.watchlistListId = defaultListId
                try await item.save(on: tx)
            }

            try await list.delete(on: tx)
        }

        return .noContent
    }

    func makeWatchlistItemResponse(from model: WatchlistItem) -> WatchlistItemResponse {
        let id = model.id ?? UUID()
        let status = WatchlistStatus(rawValue: model.status) ?? .active
        return WatchlistItemResponse(
            id: id.uuidString,
            symbol: model.symbol,
            note: model.note,
            status: status,
            createdAt: formatISODateTime(model.createdAt),
            updatedAt: formatISODateTime(model.updatedAt),
            lastReviewedAt: formatISODateOnly(model.lastReviewedAt),
            nextReviewAt: formatISODateOnly(model.nextReviewAt),
            watchlistListId: model.watchlistListId.uuidString
        )
    }

    func makeWatchlistListResponse(from model: WatchlistList) -> WatchlistListResponse {
        let id = model.id ?? UUID()
        return WatchlistListResponse(
            id: id.uuidString,
            name: model.name,
            isDefault: model.isDefault,
            createdAt: formatISODateTime(model.createdAt),
            updatedAt: formatISODateTime(model.updatedAt)
        )
    }

    private func readWatchlistCsvUpload(_ req: Request) async throws -> String {
        let maxBytes = 5 * 1024 * 1024

        if req.headers.contentType?.type.lowercased() == "multipart" {
            let upload = try req.content.decode(WatchlistCsvMultipartUpload.self)
            guard var buffer = (upload.file ?? upload.csv)?.data else {
                throw Abort(.badRequest, reason: "Missing file field in multipart body.")
            }
            guard buffer.readableBytes <= maxBytes else {
                throw Abort(.payloadTooLarge, reason: "CSV file must be 5 MB or smaller.")
            }
            guard let csv = buffer.readString(length: buffer.readableBytes) else {
                throw Abort(.badRequest, reason: "CSV file must be UTF-8 text.")
            }
            return csv
        }

        guard var buffer = try await req.body.collect(max: maxBytes).get() else {
            throw Abort(.badRequest, reason: "Missing CSV body.")
        }
        guard let csv = buffer.readString(length: buffer.readableBytes) else {
            throw Abort(.badRequest, reason: "CSV body must be UTF-8 text.")
        }
        return csv
    }
}
