import Fluent
import Foundation
import Vapor

struct StockController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())

        let stocks = protected.grouped("stocks")
        stocks.get(use: listStocks)
        stocks.post(use: createStock)
        stocks.post("bulk", use: bulkCreateStocks)
        stocks.get(":symbol", "insights", use: getStockInsights)
        stocks.group("symbol", ":symbol", "valuation") { valuation in
            valuation.get(use: getStockValuation)
            valuation.post(use: createStockValuation)
            valuation.put(use: updateStockValuation)
        }
        stocks.group(":stockId") { stock in
            stock.get(use: getStock)
            stock.put(use: updateStock)
            stock.delete(use: deleteStock)
        }

        let watchlist = protected.grouped("watchlist")
        watchlist.get(use: listWatchlist)
        watchlist.post(use: createWatchlistItem)
        watchlist.group(":watchlistId") { item in
            item.patch(use: updateWatchlistItem)
            item.delete(use: deleteWatchlistItem)
        }

        let research = protected.grouped("research")
        research.get(use: listResearch)
        research.post(use: createResearch)
        research.group(":researchId") { note in
            note.get(use: getResearch)
            note.put(use: updateResearch)
            note.delete(use: deleteResearch)
        }

        let targets = protected.grouped("targets")
        targets.get(use: listTargets)
        targets.post(use: createTarget)
        targets.group(":targetId") { target in
            target.put(use: updateTarget)
            target.delete(use: deleteTarget)
        }
    }

    @Sendable
    func listStocks(req: Request) async throws -> [StockResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await req.stocksService.list(userId: session.userId, on: req.db)
    }

    @Sendable
    func createStock(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(StockRequest.self)
        let created = try await req.stocksService.create(
            payload: payload, userId: session.userId, on: req.db)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func bulkCreateStocks(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(BulkStockRequest.self)
        let result = try await req.stocksService.bulkCreate(
            payloads: payload.stocks, userId: session.userId, on: req.db)
        let res = Response(status: .ok)
        try res.content.encode(result)
        return res
    }

    @Sendable
    func getStock(req: Request) async throws -> StockResponse {
        let session = try req.auth.require(SessionToken.self)
        let stockId = try requireUUIDParameter(req, name: "stockId", reason: "Invalid stock ID")
        return try await req.stocksService.get(
            id: stockId, userId: session.userId, on: req.db)
    }

    @Sendable
    func updateStock(req: Request) async throws -> StockResponse {
        let session = try req.auth.require(SessionToken.self)
        let stockId = try requireUUIDParameter(req, name: "stockId", reason: "Invalid stock ID")
        let payload = try req.content.decode(StockRequest.self)
        return try await req.stocksService.update(
            id: stockId, payload: payload, userId: session.userId, on: req.db)
    }

    @Sendable
    func getStockInsights(req: Request) async throws -> StockInsightsResponse {
        let session = try req.auth.require(SessionToken.self)
        let symbol = try requireStringParameter(req, name: "symbol", reason: "Invalid stock symbol")
        return try await req.stocksService.getInsights(
            symbol: symbol,
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func deleteStock(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let stockId = try requireUUIDParameter(req, name: "stockId", reason: "Invalid stock ID")
        try await req.stocksService.delete(
            id: stockId, userId: session.userId, on: req.db)
        return .noContent
    }

    @Sendable
    func getStockValuation(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let symbol = try requireStringParameter(req, name: "symbol", reason: "Invalid stock symbol")
        do {
            let valuation = try await req.stocksService.getValuation(
                symbol: symbol,
                userId: session.userId,
                on: req.db
            )
            let res = Response(status: .ok)
            logValuationResponseBody(valuation, req: req, operation: "get")
            try res.content.encode(valuation)
            return res
        } catch let error as StockServiceError {
            switch error {
            case .notFound, .valuationNotFound:
                return Response(status: .notFound)
            case .invalidSymbol, .valuationAlreadyExists:
                throw error
            }
        }
    }

    @Sendable
    func createStockValuation(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let symbol = try requireStringParameter(req, name: "symbol", reason: "Invalid stock symbol")
        let payload = try req.content.decode(StockValuationRequest.self)
        req.logger.debug(
            """
            stock.valuation.create routeSymbol=\(String(reflecting: symbol)) \
            bodySymbol=\(String(reflecting: payload.symbol)) \
            userId=\(session.userId.uuidString)
            """
        )
        let created = try await req.stocksService.createValuation(
            symbol: symbol,
            payload: payload,
            userId: session.userId,
            on: req.db
        )
        let res = Response(status: .created)
        logValuationResponseBody(created, req: req, operation: "create")
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateStockValuation(req: Request) async throws -> StockValuationRequest {
        let session = try req.auth.require(SessionToken.self)
        let symbol = try requireStringParameter(req, name: "symbol", reason: "Invalid stock symbol")
        let payload = try req.content.decode(StockValuationRequest.self)
        req.logger.debug(
            """
            stock.valuation.update routeSymbol=\(String(reflecting: symbol)) \
            bodySymbol=\(String(reflecting: payload.symbol)) \
            userId=\(session.userId.uuidString)
            """
        )
        let updated = try await req.stocksService.updateValuation(
            symbol: symbol,
            payload: payload,
            userId: session.userId,
            on: req.db
        )
        logValuationResponseBody(updated, req: req, operation: "update")
        return updated
    }

    @Sendable
    func listWatchlist(req: Request) async throws -> [WatchlistItemResponse] {
        let session = try req.auth.require(SessionToken.self)

        let items = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)
            .all()

        return try items.map(makeWatchlistItemResponse)
    }

    @Sendable
    func createWatchlistItem(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(WatchlistItemRequest.self)
        let symbol = try normalizeSymbol(payload.symbol)
        let note = emptyToNil(payload.note)
        let nextReviewAt = try parseISODateOnly(payload.nextReviewAt, field: "nextReviewAt")

        if let existing = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == session.userId)
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
            try res.content.encode(try makeWatchlistItemResponse(from: existing))
            return res
        }

        let item = WatchlistItem(
            userId: session.userId,
            symbol: symbol,
            note: note,
            status: payload.status ?? .active,
            nextReviewAt: nextReviewAt
        )
        try await item.save(on: req.db)
        let res = Response(status: .created)
        try res.content.encode(try makeWatchlistItemResponse(from: item))
        return res
    }

    @Sendable
    func updateWatchlistItem(req: Request) async throws -> WatchlistItemResponse {
        let session = try req.auth.require(SessionToken.self)
        let watchlistId = try requireUUIDParameter(
            req, name: "watchlistId", reason: "Invalid watchlist ID")
        let payload = try req.content.decode(WatchlistItemUpdateRequest.self)

        guard
            let item = try await WatchlistItem.query(on: req.db)
                .filter(\.$id == watchlistId)
                .filter(\.$userId == session.userId)
                .first()
        else {
            throw Abort(.notFound, reason: "Watchlist item not found.")
        }

        var didChange = false

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

        return try makeWatchlistItemResponse(from: item)
    }

    @Sendable
    func deleteWatchlistItem(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let watchlistId = try requireUUIDParameter(
            req, name: "watchlistId", reason: "Invalid watchlist ID")

        guard
            let item = try await WatchlistItem.query(on: req.db)
                .filter(\.$id == watchlistId)
                .filter(\.$userId == session.userId)
                .first()
        else {
            throw Abort(.notFound, reason: "Watchlist item not found.")
        }

        try await item.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func listResearch(req: Request) async throws -> [ResearchNoteResponse] {
        let session = try req.auth.require(SessionToken.self)
        let symbolFilter = req.query[String.self, at: "symbol"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let query = ResearchNote.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)

        if let symbolFilter, !symbolFilter.isEmpty {
            query.filter(\.$symbol == symbolFilter)
        }

        let notes = try await query.all()

        return try notes.map(makeResearchNoteResponse)
    }

    @Sendable
    func createResearch(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(ResearchNoteRequest.self)

        let note = ResearchNote(
            userId: session.userId,
            symbol: try normalizeSymbol(payload.symbol),
            title: emptyToNil(payload.title),
            thesis: try requireNonEmpty(payload.thesis, field: "thesis"),
            risks: emptyToNil(payload.risks),
            catalysts: emptyToNil(payload.catalysts),
            referenceLinks: try encodeReferenceLinks(payload.referenceLinks)
        )
        try await note.save(on: req.db)

        let created = try makeResearchNoteResponse(from: note)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func getResearch(req: Request) async throws -> ResearchNoteResponse {
        let session = try req.auth.require(SessionToken.self)
        let researchId = try requireUUIDParameter(
            req, name: "researchId", reason: "Invalid research ID")

        guard
            let note = try await ResearchNote.query(on: req.db)
                .filter(\.$id == researchId)
                .filter(\.$userId == session.userId)
                .first()
        else {
            throw Abort(.notFound, reason: "Research note not found.")
        }

        return try makeResearchNoteResponse(from: note)
    }

    @Sendable
    func updateResearch(req: Request) async throws -> ResearchNoteResponse {
        let session = try req.auth.require(SessionToken.self)
        let researchId = try requireUUIDParameter(
            req, name: "researchId", reason: "Invalid research ID")
        let payload = try req.content.decode(ResearchNoteRequest.self)

        guard
            let note = try await ResearchNote.query(on: req.db)
                .filter(\.$id == researchId)
                .filter(\.$userId == session.userId)
                .first()
        else {
            throw Abort(.notFound, reason: "Research note not found.")
        }

        note.symbol = try normalizeSymbol(payload.symbol)
        note.title = emptyToNil(payload.title)
        note.thesis = try requireNonEmpty(payload.thesis, field: "thesis")
        note.risks = emptyToNil(payload.risks)
        note.catalysts = emptyToNil(payload.catalysts)
        note.referenceLinks = try encodeReferenceLinks(payload.referenceLinks)
        try await note.save(on: req.db)

        return try makeResearchNoteResponse(from: note)
    }

    @Sendable
    func deleteResearch(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let researchId = try requireUUIDParameter(
            req, name: "researchId", reason: "Invalid research ID")

        guard
            let note = try await ResearchNote.query(on: req.db)
                .filter(\.$id == researchId)
                .filter(\.$userId == session.userId)
                .first()
        else {
            throw Abort(.notFound, reason: "Research note not found.")
        }

        try await note.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func listTargets(req: Request) async throws -> [TargetResponse] {
        let session = try req.auth.require(SessionToken.self)
        let symbolFilter = req.query[String.self, at: "symbol"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()

        let query = Target.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)

        if let symbolFilter, !symbolFilter.isEmpty {
            query.filter(\.$symbol == symbolFilter)
        }

        let targets = try await query.all()
        return try targets.map(makeTargetResponse)
    }

    @Sendable
    func createTarget(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(TargetRequest.self)

        let target = Target(
            userId: session.userId,
            symbol: try normalizeSymbol(payload.symbol),
            scenario: try normalizeScenario(payload.scenario),
            targetPrice: payload.targetPrice,
            targetDate: try parseISODateOnly(payload.targetDate, field: "targetDate"),
            rationale: emptyToNil(payload.rationale)
        )
        try await target.save(on: req.db)

        let created = try makeTargetResponse(from: target)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateTarget(req: Request) async throws -> TargetResponse {
        let session = try req.auth.require(SessionToken.self)
        let targetId = try requireUUIDParameter(req, name: "targetId", reason: "Invalid target ID")
        let payload = try req.content.decode(TargetRequest.self)

        guard
            let target = try await Target.query(on: req.db)
                .filter(\.$id == targetId)
                .filter(\.$userId == session.userId)
                .first()
        else {
            throw Abort(.notFound, reason: "Target not found.")
        }

        target.symbol = try normalizeSymbol(payload.symbol)
        target.scenario = try normalizeScenario(payload.scenario)
        target.targetPrice = payload.targetPrice
        target.targetDate = try parseISODateOnly(payload.targetDate, field: "targetDate")
        target.rationale = emptyToNil(payload.rationale)
        try await target.save(on: req.db)

        return try makeTargetResponse(from: target)
    }

    @Sendable
    func deleteTarget(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let targetId = try requireUUIDParameter(req, name: "targetId", reason: "Invalid target ID")

        guard
            let target = try await Target.query(on: req.db)
                .filter(\.$id == targetId)
                .filter(\.$userId == session.userId)
                .first()
        else {
            throw Abort(.notFound, reason: "Target not found.")
        }

        try await target.delete(on: req.db)
        return .noContent
    }

    private func requireUUIDParameter(_ req: Request, name: String, reason: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: reason)
        }
        return value
    }

    private func requireStringParameter(_ req: Request, name: String, reason: String) throws -> String {
        guard let raw = req.parameters.get(name) else {
            throw Abort(.badRequest, reason: reason)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: reason)
        }
        return trimmed
    }

    private func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return normalized
    }

    private func requireNonEmpty(_ raw: String, field: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "\(field) is required.")
        }
        return trimmed
    }

    private func emptyToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeScenario(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["bear", "base", "bull"].contains(normalized) else {
            throw Abort(.badRequest, reason: "scenario must be one of: bear, base, bull.")
        }
        return normalized
    }

    private func parseISODateOnly(_ raw: String?, field: String) throws -> Date? {
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

    private func formatISODateOnly(_ date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func formatISODateTime(_ date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func encodeReferenceLinks(_ links: [String]?) throws -> String? {
        guard let links else { return nil }

        let cleaned =
            links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return nil }

        let data = try JSONEncoder().encode(cleaned)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeReferenceLinks(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private func makeWatchlistItemResponse(from model: WatchlistItem) throws
        -> WatchlistItemResponse
    {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Watchlist item id missing.")
        }
        guard let status = WatchlistStatus(rawValue: model.status) else {
            throw Abort(.internalServerError, reason: "Watchlist item status is invalid.")
        }
        return WatchlistItemResponse(
            id: id.uuidString,
            symbol: model.symbol,
            note: model.note,
            status: status,
            createdAt: formatISODateTime(model.createdAt),
            updatedAt: formatISODateTime(model.updatedAt),
            lastReviewedAt: formatISODateOnly(model.lastReviewedAt),
            nextReviewAt: formatISODateOnly(model.nextReviewAt)
        )
    }

    private func makeResearchNoteResponse(from model: ResearchNote) throws -> ResearchNoteResponse {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Research note id missing.")
        }
        return ResearchNoteResponse(
            id: id.uuidString,
            symbol: model.symbol,
            title: model.title,
            thesis: model.thesis,
            risks: model.risks,
            catalysts: model.catalysts,
            referenceLinks: decodeReferenceLinks(model.referenceLinks)
        )
    }

    private func makeTargetResponse(from model: Target) throws -> TargetResponse {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Target id missing.")
        }
        return TargetResponse(
            id: id.uuidString,
            symbol: model.symbol,
            scenario: model.scenario,
            targetPrice: model.targetPrice,
            targetDate: formatISODateOnly(model.targetDate),
            rationale: model.rationale
        )
    }
}

private func logValuationResponseBody(
    _ valuation: StockValuationRequest,
    req: Request,
    operation: String
) {
    do {
        let data = try JSONEncoder().encode(valuation)
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        req.logger.debug(
            "stock.valuation.\(operation).response statusBody=\(body)"
        )
    } catch {
        req.logger.error(
            "stock.valuation.\(operation).response.encode_failed error=\(error.localizedDescription)"
        )
    }
}
