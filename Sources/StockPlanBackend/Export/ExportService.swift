import Fluent
import Foundation
import NIOCore
import StockPlanShared
import Vapor

struct ExportService: @unchecked Sendable {
    let repository: any DataExportRepository
    let application: Application

    private let exportsBaseDir: String

    init(repository: any DataExportRepository, application: Application) {
        self.repository = repository
        self.application = application
        exportsBaseDir = application.directory.workingDirectory + ".build/exports"
    }

    func createExportJob(
        userId: UUID,
        type: ExportType,
        format: ExportFormat,
        filters: ExportFilters?,
        on db: any Database
    ) async throws -> DataExport {
        let export = DataExport(
            userId: userId,
            type: type,
            format: format,
            filters: filters,
            status: .pending
        )
        let savedExport = try await repository.create(export, on: db)

        // Schedule background task
        Task {
            try? await generateExport(exportId: savedExport.id!, userId: userId, type: type, format: format, filters: filters, on: db)
        }

        return savedExport
    }

    func getExportStatus(id: UUID, userId: UUID, on db: any Database) async throws -> DataExport? {
        try await repository.find(id: id, userId: userId, on: db)
    }

    func listExports(userId: UUID, limit: Int, offset: Int, on db: any Database) async throws -> [DataExport] {
        try await repository.list(userId: userId, limit: limit, offset: offset, on: db)
    }

    private func generateExport(
        exportId: UUID,
        userId: UUID,
        type: ExportType,
        format: ExportFormat,
        filters: ExportFilters?,
        on db: any Database
    ) async throws {
        // Convert string-based filters to native types
        let dateFormatter = ISO8601DateFormatter()
        let startDate = filters?.dateFrom.flatMap { dateFormatter.date(from: $0) }
        let endDate = filters?.dateTo.flatMap { dateFormatter.date(from: $0) }
        let portfolioListID = filters?.portfolioListId.flatMap { UUID(uuidString: $0) }

        let userDir = "\(exportsBaseDir)/\(userId)"
        let fileExtension = format == .csv ? "csv" : "json"
        let filePath = "\(userDir)/\(exportId).\(fileExtension)"

        do {
            try FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true, attributes: nil)
            var fileSize: Int64 = 0

            switch format {
            case .csv:
                fileSize = try await generateCSV(dataType: type, filePath: filePath, userId: userId, startDate: startDate, endDate: endDate, portfolioListId: portfolioListID, on: db)
            case .json:
                fileSize = try await generateJSON(dataType: type, filePath: filePath, userId: userId, startDate: startDate, endDate: endDate, portfolioListId: portfolioListID, on: db)
            }

            if var existingExport = try await repository.find(id: exportId, userId: userId, on: db) {
                existingExport.status = ExportStatus.ready.rawValue
                existingExport.filePath = filePath
                existingExport.fileSizeBytes = fileSize
                existingExport.expiresAt = Calendar.current.date(byAdding: .day, value: 7, to: Date())
                try await repository.update(existingExport, on: db)
            }
        } catch {
            if var existingExport = try? await repository.find(id: exportId, userId: userId, on: db) {
                existingExport.status = ExportStatus.failed.rawValue
                try? await repository.update(existingExport, on: db)
            }
            application.logger.error("export.generation.failed exportId=\(exportId) error=\(error)")
        }
    }

    private func generateCSV(
        dataType: ExportType,
        filePath: String,
        userId: UUID,
        startDate: Date?,
        endDate: Date?,
        portfolioListId: UUID?,
        on db: any Database
    ) async throws -> Int64 {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let rows = try await getExportRows(dataType: dataType, userId: userId, startDate: startDate, endDate: endDate, portfolioListId: portfolioListId, on: db)

        var csvData = Data(bom)
        if let headers = rows.first?.csvHeaders() {
            csvData.append(Data(headers.utf8) + Data("\n".utf8))
        }
        for row in rows {
            let line = row.csvRow() + "\n"
            csvData.append(Data(line.utf8))
        }

        try csvData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        return Int64(csvData.count)
    }

    private func generateJSON(
        dataType: ExportType,
        filePath: String,
        userId: UUID,
        startDate: Date?,
        endDate: Date?,
        portfolioListId: UUID?,
        on db: any Database
    ) async throws -> Int64 {
        let rows = try await getExportRows(dataType: dataType, userId: userId, startDate: startDate, endDate: endDate, portfolioListId: portfolioListId, on: db)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encodableRows = rows.map { AnyEncodable(value: $0) }
        let data = try encoder.encode(encodableRows)
        try data.write(to: URL(fileURLWithPath: filePath))
        return Int64(data.count)
    }

    private func getExportRows(
        dataType: ExportType,
        userId: UUID,
        startDate: Date?,
        endDate: Date?,
        portfolioListId: UUID?,
        on db: any Database
    ) async throws -> [any ExportRow] {
        switch dataType {
        case .portfolio:
            try await getPortfolioRows(userId: userId, portfolioListId: portfolioListId, on: db)
        case .transactions:
            try await getTransactionRows(userId: userId, startDate: startDate, endDate: endDate, on: db)
        case .watchlist:
            try await getWatchlistRows(userId: userId, on: db)
        case .insights:
            try await getInsightsRows(userId: userId, on: db)
        case .all:
            // For now, return a placeholder manifest
            try await [ExportAllManifestRow(
                portfolioCount: getPortfolioRows(userId: userId, portfolioListId: portfolioListId, on: db).count,
                transactionCount: getTransactionRows(userId: userId, startDate: startDate, endDate: endDate, on: db).count,
                watchlistCount: getWatchlistRows(userId: userId, on: db).count,
                insightsCount: getInsightsRows(userId: userId, on: db).count
            )]
        }
    }

    private func getPortfolioRows(userId: UUID, portfolioListId: UUID?, on db: any Database) async throws -> [PortfolioExportRow] {
        var query = Stock.query(on: db).filter(\.$userId == userId)
        if let portfolioListId {
            query = query.filter(\.$portfolioListId == portfolioListId)
        }
        let stocks = try await query.all()
        return stocks.map { stock in
            PortfolioExportRow(
                id: stock.id?.uuidString ?? "",
                symbol: stock.symbol,
                shares: stock.shares,
                buyPrice: stock.buyPrice,
                buyDate: stock.buyDate,
                notes: stock.notes,
                category: stock.category.rawValue,
                portfolioListId: stock.portfolioListId.uuidString,
                createdAt: stock.createdAt ?? Date()
            )
        }
    }

    private func getTransactionRows(userId: UUID, startDate: Date?, endDate: Date?, on db: any Database) async throws -> [TransactionExportRow] {
        // Get user's account IDs
        let accounts = try await Account.query(on: db).filter(\.$userId == userId).all()
        let accountIds = accounts.map { $0.id! }
        guard !accountIds.isEmpty else { return [] }

        var query = Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIds)
        if let startDate {
            query = query.filter(\.$tradeDate >= startDate)
        }
        if let endDate {
            query = query.filter(\.$tradeDate <= endDate)
        }
        let transactions = try await query.all()
        return transactions.map { t in
            TransactionExportRow(
                id: t.id?.uuidString ?? "",
                accountId: t.accountId.uuidString,
                instrumentId: t.instrumentId.uuidString,
                externalId: t.externalId,
                type: t.type,
                quantity: t.quantity,
                price: t.price,
                currency: t.currency,
                tradeDate: t.tradeDate,
                settleDate: t.settleDate,
                fees: t.fees
            )
        }
    }

    private func getWatchlistRows(userId: UUID, on db: any Database) async throws -> [WatchlistExportRow] {
        let items = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .all()
        return items.map { item in
            WatchlistExportRow(
                id: item.id?.uuidString ?? "",
                symbol: item.symbol,
                note: item.note,
                status: item.status,
                watchlistListId: item.watchlistListId.uuidString,
                lastReviewedAt: item.lastReviewedAt,
                nextReviewAt: item.nextReviewAt,
                createdAt: item.createdAt ?? Date()
            )
        }
    }

    private func getInsightsRows(userId: UUID, on db: any Database) async throws -> [InsightExportRow] {
        let notes = try await ResearchNote.query(on: db)
            .filter(\.$userId == userId)
            .all()
        return notes.map { note in
            InsightExportRow(
                id: note.id?.uuidString ?? "",
                symbol: note.symbol,
                title: note.title,
                thesis: note.thesis,
                risks: note.risks,
                catalysts: note.catalysts,
                referenceLinks: note.referenceLinks,
                createdAt: note.createdAt ?? Date()
            )
        }
    }
}

protocol ExportRow: Encodable {
    func csvHeaders() -> String
    func csvRow() -> String
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }
}

struct PortfolioExportRow: ExportRow, Encodable {
    let id: String
    let symbol: String
    let shares: Double
    let buyPrice: Double
    let buyDate: Date
    let notes: String?
    let category: String
    let portfolioListId: String
    let createdAt: Date

    func csvHeaders() -> String {
        "id,symbol,shares,buyPrice,buyDate,notes,category,portfolioListId,createdAt"
    }

    func csvRow() -> String {
        let notesEscaped = (notes ?? "").replacingOccurrences(of: "\"", with: "\"\"")
        let dateFormatter = ISO8601DateFormatter()
        return "\"\(id)\",\"\(symbol)\",\(shares),\(buyPrice),\"\(dateFormatter.string(from: buyDate))\",\"\(notesEscaped)\",\"\(category)\",\"\(portfolioListId)\",\"\(dateFormatter.string(from: createdAt))\""
    }
}

struct TransactionExportRow: ExportRow, Encodable {
    let id: String
    let accountId: String
    let instrumentId: String
    let externalId: String?
    let type: String
    let quantity: Double?
    let price: Double?
    let currency: String
    let tradeDate: Date
    let settleDate: Date?
    let fees: Double?

    func csvHeaders() -> String {
        "id,accountId,instrumentId,externalId,type,quantity,price,currency,tradeDate,settleDate,fees"
    }

    func csvRow() -> String {
        let dateFormatter = ISO8601DateFormatter()
        let extId = externalId ?? ""
        let qty = quantity.map { String($0) } ?? ""
        let pr = price.map { String($0) } ?? ""
        let settle = settleDate.map { dateFormatter.string(from: $0) } ?? ""
        let feesVal = fees.map { String($0) } ?? ""
        return "\"\(id)\",\"\(accountId)\",\"\(instrumentId)\",\"\(extId)\",\"\(type)\",\"\(qty)\",\"\(pr)\",\"\(currency)\",\"\(dateFormatter.string(from: tradeDate))\",\"\(settle)\",\"\(feesVal)\""
    }
}

struct WatchlistExportRow: ExportRow, Encodable {
    let id: String
    let symbol: String
    let note: String?
    let status: String
    let watchlistListId: String
    let lastReviewedAt: Date?
    let nextReviewAt: Date?
    let createdAt: Date

    func csvHeaders() -> String {
        "id,symbol,note,status,watchlistListId,lastReviewedAt,nextReviewAt,createdAt"
    }

    func csvRow() -> String {
        let dateFormatter = ISO8601DateFormatter()
        let noteEscaped = (note ?? "").replacingOccurrences(of: "\"", with: "\"\"")
        let lastRev = lastReviewedAt.map { dateFormatter.string(from: $0) } ?? ""
        let nextRev = nextReviewAt.map { dateFormatter.string(from: $0) } ?? ""
        return "\"\(id)\",\"\(symbol)\",\"\(noteEscaped)\",\"\(status)\",\"\(watchlistListId)\",\"\(lastRev)\",\"\(nextRev)\",\"\(dateFormatter.string(from: createdAt))\""
    }
}

struct InsightExportRow: ExportRow, Encodable {
    let id: String
    let symbol: String
    let title: String?
    let thesis: String
    let risks: String?
    let catalysts: String?
    let referenceLinks: String?
    let createdAt: Date

    func csvHeaders() -> String {
        "id,symbol,title,thesis,risks,catalysts,referenceLinks,createdAt"
    }

    func csvRow() -> String {
        let dateFormatter = ISO8601DateFormatter()
        let titleEsc = (title ?? "").replacingOccurrences(of: "\"", with: "\"\"")
        let thesisEsc = thesis.replacingOccurrences(of: "\"", with: "\"\"")
        let risksEsc = (risks ?? "").replacingOccurrences(of: "\"", with: "\"\"")
        let catEsc = (catalysts ?? "").replacingOccurrences(of: "\"", with: "\"\"")
        let refEsc = (referenceLinks ?? "").replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(id)\",\"\(symbol)\",\"\(titleEsc)\",\"\(thesisEsc)\",\"\(risksEsc)\",\"\(catEsc)\",\"\(refEsc)\",\"\(dateFormatter.string(from: createdAt))\""
    }
}

struct ExportAllManifestRow: ExportRow, Encodable {
    let portfolioCount: Int
    let transactionCount: Int
    let watchlistCount: Int
    let insightsCount: Int

    func csvHeaders() -> String {
        "portfolioCount,transactionCount,watchlistCount,insightsCount"
    }

    func csvRow() -> String {
        "\(portfolioCount),\(transactionCount),\(watchlistCount),\(insightsCount)"
    }
}

extension String {
    func utf8Data() -> Data {
        data(using: .utf8) ?? Data()
    }
}
