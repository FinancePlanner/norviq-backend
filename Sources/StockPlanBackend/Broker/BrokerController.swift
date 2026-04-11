import Vapor
import Foundation
import NIOCore
import Fluent

struct BrokerController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let brokers = routes.grouped("brokers")
        let protected = brokers.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.get(use: listBrokers)
        protected.get("holdings", use: listHoldings)
        protected.get(":provider", use: getBroker)
        protected.post("import", "csv", use: importCsvPreview)
        protected.post("import", "csv", "commit", use: importCsvCommit)
        protected.post("ibkr", "sync", use: syncIbkr)
    }

    @Sendable
    func listBrokers(req: Request) async throws -> [BrokerConnectionResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.brokersService.list(userId: session.userId, on: req.db)
    }

    @Sendable
    func getBroker(req: Request) async throws -> BrokerConnectionResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let provider = req.parameters.get("provider") else {
            throw Abort(.badRequest, reason: "Missing broker provider")
        }
        return try await req.application.brokersService.get(provider: provider, userId: session.userId, on: req.db)
    }

    @Sendable
    func listHoldings(req: Request) async throws -> [BrokerHoldingResponse] {
        let session = try req.auth.require(SessionToken.self)
        let stocks = try await req.application.stocksRepository.list(
            userId: session.userId,
            portfolioListId: nil,
            on: req.db
        )

        return stocks.map {
            BrokerHoldingResponse(symbol: $0.symbol, quantity: $0.shares, currency: "USD")
        }
    }

    @Sendable
    func syncIbkr(req: Request) async throws -> BrokerSyncResponse {
        _ = try req.auth.require(SessionToken.self)
        return BrokerSyncResponse(runId: UUID().uuidString, status: "accepted")
    }

    @Sendable
    func importCsvPreview(req: Request) async throws -> CsvImportPreviewResponse {
        let upload = try await readCsvUpload(req)
        return try CsvImportService().preview(csv: upload.csv, provider: upload.provider)
    }

    @Sendable
    func importCsvCommit(req: Request) async throws -> CsvImportCommitResponse {
        let session = try req.auth.require(SessionToken.self)
        let upload = try await readCsvUpload(req)

        let preview = try CsvImportService().preview(csv: upload.csv, provider: upload.provider)
        let broker = try await req.application.brokersService.recordCsvImport(provider: upload.provider, userId: session.userId, on: req.db)
        var inserted: [StockResponse] = []
        var updated: [StockResponse] = []
        var errors = preview.errors

        for item in preview.items {
            let hasPositionData = item.shares != nil || item.buyPrice != nil || item.buyDate != nil
            if !hasPositionData {
                do {
                    try await req.db.transaction { tx in
                        try await upsertWatchlistItem(symbol: item.symbol, userId: session.userId, on: tx)
                    }
                } catch {
                    let message: String
                    if let abortError = error as? any AbortError {
                        message = abortError.reason
                    } else {
                        message = "Failed to import watchlist row."
                    }
                    errors.append(.init(line: item.line, message: message))
                }
                continue
            }

            do {
                let rowResult = try await req.db.transaction { tx -> (stock: StockResponse, wasUpdate: Bool) in
                    let existing = try await req.application.stocksRepository.find(
                        symbol: item.symbol,
                        userId: session.userId,
                        on: tx
                    )

                    guard let shares = item.shares ?? existing?.shares else {
                        throw Abort(.badRequest, reason: "Missing shares (quantity).")
                    }

                    guard let buyPrice = item.buyPrice ?? existing?.buyPrice else {
                        throw Abort(.badRequest, reason: "Missing buyPrice (average_cost).")
                    }

                    let buyDate: String
                    if let rawBuyDate = item.buyDate, let normalized = CsvImportService.normalizeDateOnlyString(rawBuyDate) {
                        buyDate = normalized
                    } else if let existing, let existingResponse = try? StockResponse(from: existing) {
                        buyDate = existingResponse.buyDate
                    } else {
                        throw Abort(.badRequest, reason: "Missing or invalid buyDate. Expected YYYY-MM-DD.")
                    }

                    let notes = item.notes ?? existing?.notes
                    let payload = StockRequest(
                        symbol: item.symbol,
                        shares: shares,
                        buyPrice: buyPrice,
                        buyDate: buyDate,
                        notes: notes
                    )

                    if let existing, let id = existing.id {
                        let stock = try await req.stocksService.update(
                            id: id,
                            payload: payload,
                            userId: session.userId,
                            on: tx
                        )
                        return (stock, true)
                    }

                    let stock = try await req.stocksService.create(
                        payload: payload,
                        userId: session.userId,
                        on: tx
                    )
                    return (stock, false)
                }

                if rowResult.wasUpdate {
                    updated.append(rowResult.stock)
                } else {
                    inserted.append(rowResult.stock)
                }
            } catch {
                let message: String
                if let abortError = error as? any AbortError {
                    message = abortError.reason
                } else {
                    message = "Failed to import row."
                }
                errors.append(.init(line: item.line, message: message))
            }
        }

        return .init(provider: broker.provider, inserted: inserted, updated: updated, errors: errors)
    }

    private func upsertWatchlistItem(symbol rawSymbol: String, userId: UUID, on db: any Database) async throws {
        let symbol = rawSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        guard let targetListId = try await resolveWatchlistListId(
            requestedId: nil,
            userId: userId,
            on: db,
            defaultWhenMissing: true
        ) else {
            throw Abort(.internalServerError, reason: "Failed to resolve default watchlist list.")
        }

        if let existing = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$watchlistListId == targetListId)
            .filter(\.$symbol == symbol)
            .first() {
            if existing.status == "archived" {
                existing.status = "active"
                try await existing.save(on: db)
            }
            return
        }

        let item = WatchlistItem(userId: userId, watchlistListId: targetListId, symbol: symbol)
        try await item.save(on: db)
    }

    private struct CsvMultipartUpload: Content {
        var provider: String?
        var file: File?
        var csv: File?
    }

    private func readCsvUpload(_ req: Request) async throws -> (provider: String, csv: String) {
        if req.headers.contentType?.type.lowercased() == "multipart" {
            let upload = try req.content.decode(CsvMultipartUpload.self)
            let provider = try requireProvider(req, multipartValue: upload.provider)
            guard var buffer = (upload.file ?? upload.csv)?.data else {
                throw Abort(.badRequest, reason: "Missing file field in multipart body.")
            }
            guard let csv = buffer.readString(length: buffer.readableBytes) else {
                throw Abort(.badRequest, reason: "CSV file must be UTF-8 text.")
            }
            return (provider: provider, csv: csv)
        }

        let provider = try requireProvider(req, multipartValue: nil)
        let maxBytes = 5 * 1024 * 1024
        guard var buffer = try await req.body.collect(max: maxBytes).get() else {
            throw Abort(.badRequest, reason: "Missing CSV body.")
        }
        guard let csv = buffer.readString(length: buffer.readableBytes) else {
            throw Abort(.badRequest, reason: "CSV body must be UTF-8 text.")
        }
        return (provider: provider, csv: csv)
    }

    private func requireProvider(_ req: Request, multipartValue: String?) throws -> String {
        let raw = multipartValue
            ?? req.query[String.self, at: "provider"]
            ?? req.query[String.self, at: "broker"]
            ?? req.headers.first(name: "X-Broker-Provider")

        guard let raw else {
            throw Abort(.badRequest, reason: "Missing broker provider. Use ?provider=... or multipart field provider.")
        }

        return try BrokerProvider.normalize(raw)
    }
}
