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
        let stocks = try await req.application.stocksRepository.list(userId: session.userId, on: req.db)

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
                    try await upsertWatchlistItem(symbol: item.symbol, userId: session.userId, on: req.db)
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

            let existing = try await req.application.stocksRepository.find(symbol: item.symbol, userId: session.userId, on: req.db)

            guard let shares = item.shares ?? existing?.shares else {
                errors.append(.init(line: item.line, message: "Missing shares (quantity)."))
                continue
            }

            guard let buyPrice = item.buyPrice ?? existing?.buyPrice else {
                errors.append(.init(line: item.line, message: "Missing buyPrice (average_cost)."))
                continue
            }

            let buyDate: String
            if let rawBuyDate = item.buyDate, let normalized = CsvImportService.normalizeDateOnlyString(rawBuyDate) {
                buyDate = normalized
            } else if let existing, let existingResponse = try? StockResponse(from: existing) {
                buyDate = existingResponse.buyDate
            } else {
                errors.append(.init(line: item.line, message: "Missing or invalid buyDate. Expected YYYY-MM-DD."))
                continue
            }

            let notes = item.notes ?? existing?.notes
            let payload = StockRequest(symbol: item.symbol, shares: shares, buyPrice: buyPrice, buyDate: buyDate, notes: notes)

            do {
                if let existing, let id = existing.id {
                    let stock = try await req.application.stocksService.update(id: id, payload: payload, userId: session.userId, on: req.db)
                    updated.append(stock)
                } else {
                    let stock = try await req.application.stocksService.create(payload: payload, userId: session.userId, on: req.db)
                    inserted.append(stock)
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

        if try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$symbol == symbol)
            .first() != nil
        {
            return
        }

        let item = WatchlistItem(userId: userId, symbol: symbol)
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
