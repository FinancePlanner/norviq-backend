import Fluent
import Foundation
import StockPlanShared
import Vapor

struct CsvPortfolioImportService {
    func preview(
        csv: String,
        provider: String,
        portfolioListId rawPortfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> CsvImportPreviewResponse {
        let base = try CsvImportService().preview(csv: csv, provider: provider)
        let existingBySymbol = try await existingStockKinds(userId: userId, on: req.db)
        let sourceAccountId = try await resolveImportAccount(
            provider: provider,
            portfolioListId: rawPortfolioListId,
            userId: userId,
            createIfMissing: false,
            on: req.db
        )?.id

        var items: [CsvImportPreviewItem] = []
        var errors = base.errors
        items.reserveCapacity(base.items.count)

        for item in base.items {
            let validationError = try await validatePreviewItem(item, on: req)
            if let validationError {
                errors.append(.init(line: item.line, message: validationError))
            }

            let existing = existingBySymbol[item.symbol] ?? CsvImportExistingPositionKind.none
            let hasExistingImportedSymbolForSource: Bool = if sourceAccountId != nil, existing.hasImportedPosition {
                try await hasExistingImportedSymbol(
                    symbol: item.symbol,
                    provider: provider,
                    sourceAccountId: sourceAccountId,
                    userId: userId,
                    on: req.db
                )
            } else {
                false
            }

            items.append(
                CsvImportPreviewItem(
                    line: item.line,
                    symbol: item.symbol,
                    shares: item.shares,
                    buyPrice: item.buyPrice,
                    buyDate: item.buyDate,
                    notes: item.notes,
                    existingPositionKind: existing,
                    willReplaceExistingImport: hasExistingImportedSymbolForSource
                )
            )
        }

        return .init(provider: provider, items: items, errors: dedupeErrors(errors))
    }

    func commit(
        csv: String,
        provider: String,
        portfolioListId rawPortfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> CsvImportCommitResponse {
        let preview = try await preview(
            csv: csv,
            provider: provider,
            portfolioListId: rawPortfolioListId,
            userId: userId,
            on: req
        )
        let invalidLines = Set(preview.errors.map(\.line))
        let validItems = preview.items.filter { !invalidLines.contains($0.line) }
        let groupedItems = Dictionary(grouping: validItems, by: \.symbol)
        let targetListId = try await requirePortfolioListId(
            requestedId: rawPortfolioListId,
            userId: userId,
            on: req.db
        )

        let broker = try await req.application.brokersService.recordCsvImport(
            provider: provider,
            userId: userId,
            on: req.db
        )

        if !groupedItems.isEmpty {
            try await req.usageCounterService.incrementUsage(.csvImports, userId: userId, by: 1, on: req.db)
        }

        var inserted: [StockResponse] = []
        var updated: [StockResponse] = []
        var errors = preview.errors
        var replacedSymbols = Set<String>()
        var importedLotsCount = 0

        for (symbol, rows) in groupedItems.sorted(by: { $0.key < $1.key }) {
            do {
                let result = try await req.db.transaction { tx in
                    try await importSymbolRows(
                        rows,
                        symbol: symbol,
                        provider: provider,
                        portfolioListId: targetListId,
                        userId: userId,
                        on: req,
                        db: tx
                    )
                }

                importedLotsCount += result.lotsInserted
                if result.replacedExisting {
                    replacedSymbols.insert(symbol)
                    updated.append(result.stock)
                } else {
                    inserted.append(result.stock)
                }
            } catch {
                let message: String = if let abortError = error as? any AbortError {
                    abortError.reason
                } else {
                    "Failed to import row."
                }
                let line = rows.map(\.line).min() ?? 0
                errors.append(.init(line: line, message: message))
            }
        }

        return .init(
            provider: broker.provider,
            inserted: inserted,
            updated: updated,
            errors: dedupeErrors(errors),
            replacedSymbols: replacedSymbols.sorted(),
            importedLotsCount: importedLotsCount
        )
    }
}

private extension CsvPortfolioImportService {
    struct ImportResult {
        let stock: StockResponse
        let replacedExisting: Bool
        let lotsInserted: Int
    }

    struct NormalizedImportRow {
        let shares: Double
        let buyPrice: Double
        let buyDate: Date
        let notes: String?
    }

    func validatePreviewItem(_ item: CsvImportPreviewItem, on _: Request) async throws -> String? {
        guard let shares = item.shares, shares > 0 else {
            return "Missing or invalid shares (quantity)."
        }
        guard let buyPrice = item.buyPrice, buyPrice > 0 else {
            return "Missing or invalid buyPrice (average_cost)."
        }
        guard let rawBuyDate = item.buyDate,
              CsvImportService.normalizeDateOnlyString(rawBuyDate) != nil
        else {
            return "Missing or invalid buyDate. Expected YYYY-MM-DD."
        }
        return nil
    }

    func importSymbolRows(
        _ rows: [CsvImportPreviewItem],
        symbol: String,
        provider: String,
        portfolioListId: UUID,
        userId: UUID,
        on req: Request,
        db: any Database
    ) async throws -> ImportResult {
        let sourceAccount = try await requireImportAccount(
            provider: provider,
            portfolioListId: portfolioListId.uuidString,
            userId: userId,
            on: db
        )
        let instrument = try await requireInstrument(symbol: symbol, on: req, db: db)

        let existingImportedStocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$sourceProvider == provider)
            .filter(\.$sourceAccountId == sourceAccount.requireID())
            .filter(\.$symbol == symbol)
            .all()

        for stock in existingImportedStocks {
            try await stock.delete(on: db)
        }

        let existingLots = try await Lot.query(on: db)
            .filter(\.$accountId == sourceAccount.requireID())
            .filter(\.$instrumentId == instrument.requireID())
            .all()
        for lot in existingLots {
            try await lot.delete(on: db)
        }

        if let existingPosition = try await Position.query(on: db)
            .filter(\.$accountId == sourceAccount.requireID())
            .filter(\.$instrumentId == instrument.requireID())
            .first()
        {
            try await existingPosition.delete(on: db)
        }

        let normalizedRows = try rows.map(normalizeRequiredRow)
        let sourceAccountId = try sourceAccount.requireID()
        let instrumentId = try instrument.requireID()
        let totalShares = normalizedRows.reduce(0.0) { $0 + $1.shares }
        let totalCostBasis = normalizedRows.reduce(0.0) { $0 + ($1.shares * $1.buyPrice) }
        let averageCost = totalShares > 0 ? totalCostBasis / totalShares : 0
        let earliestBuyDate = normalizedRows.map(\.buyDate).min() ?? Date()
        let notes = normalizedRows.compactMap(\.notes).first

        for row in normalizedRows {
            let lot = Lot(
                accountId: sourceAccountId,
                instrumentId: instrumentId,
                openDate: row.buyDate,
                openQuantity: row.shares,
                remainingQuantity: row.shares,
                openPrice: row.buyPrice,
                currency: instrument.currency,
                status: "open"
            )
            try await lot.save(on: db)
        }

        let position = Position(
            accountId: sourceAccountId,
            instrumentId: instrumentId,
            quantity: totalShares,
            averageCost: averageCost,
            currency: instrument.currency
        )
        try await position.save(on: db)

        let stock = Stock(
            userId: userId,
            portfolioListId: portfolioListId,
            symbol: symbol,
            shares: totalShares,
            buyPrice: averageCost,
            buyDate: earliestBuyDate,
            notes: notes,
            category: .stock,
            sourceProvider: provider,
            sourceAccountId: sourceAccountId
        )
        try await stock.save(on: db)

        return try .init(
            stock: StockResponse(from: stock),
            replacedExisting: !existingImportedStocks.isEmpty || !existingLots.isEmpty,
            lotsInserted: normalizedRows.count
        )
    }

    func normalizeRequiredRow(_ row: CsvImportPreviewItem) throws -> NormalizedImportRow {
        guard let shares = row.shares, shares > 0 else {
            throw Abort(.badRequest, reason: "Missing or invalid shares (quantity).")
        }
        guard let buyPrice = row.buyPrice, buyPrice > 0 else {
            throw Abort(.badRequest, reason: "Missing or invalid buyPrice (average_cost).")
        }
        guard let rawBuyDate = row.buyDate,
              let normalized = CsvImportService.normalizeDateOnlyString(rawBuyDate)
        else {
            throw Abort(.badRequest, reason: "Missing or invalid buyDate. Expected YYYY-MM-DD.")
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        guard let buyDate = formatter.date(from: normalized) else {
            throw Abort(.badRequest, reason: "Missing or invalid buyDate. Expected YYYY-MM-DD.")
        }

        return .init(shares: shares, buyPrice: buyPrice, buyDate: buyDate, notes: row.notes)
    }

    func existingStockKinds(userId: UUID, on db: any Database) async throws -> [String: CsvImportExistingPositionKind] {
        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .all()

        var grouped: [String: (hasManual: Bool, hasImported: Bool)] = [:]
        for stock in stocks {
            var entry = grouped[stock.symbol] ?? (false, false)
            if stock.sourceProvider == nil {
                entry.hasManual = true
            } else {
                entry.hasImported = true
            }
            grouped[stock.symbol] = entry
        }

        return grouped.mapValues { value in
            switch (value.hasManual, value.hasImported) {
            case (false, false): CsvImportExistingPositionKind.none
            case (true, false): CsvImportExistingPositionKind.manual
            case (false, true): CsvImportExistingPositionKind.imported
            case (true, true): CsvImportExistingPositionKind.mixed
            }
        }
    }

    func hasExistingImportedSymbol(
        symbol: String,
        provider: String,
        sourceAccountId: UUID?,
        userId: UUID,
        on db: any Database
    ) async throws -> Bool {
        let query = Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$symbol == symbol)
            .filter(\.$sourceProvider == provider)

        if let sourceAccountId {
            query.filter(\.$sourceAccountId == sourceAccountId)
        }

        return try await query.first() != nil
    }

    func requirePortfolioListId(
        requestedId: String?,
        userId: UUID,
        on db: any Database
    ) async throws -> UUID {
        guard let id = try await resolvePortfolioListId(
            requestedId: requestedId,
            userId: userId,
            on: db,
            defaultWhenMissing: true
        ) else {
            throw Abort(.internalServerError, reason: "Failed to resolve portfolio list.")
        }
        return id
    }

    func resolveImportAccount(
        provider: String,
        portfolioListId: String?,
        userId: UUID,
        createIfMissing: Bool,
        on db: any Database
    ) async throws -> Account? {
        let externalId = importAccountExternalId(provider: provider, portfolioListId: portfolioListId)
        if let existing = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$broker == provider)
            .filter(\.$externalId == externalId)
            .first()
        {
            return existing
        }

        guard createIfMissing else { return nil }

        let account = Account(
            userId: userId,
            externalId: externalId,
            broker: provider,
            displayName: "\(provider.uppercased()) CSV Import",
            baseCurrency: "USD"
        )
        try await account.save(on: db)
        return account
    }

    func requireImportAccount(
        provider: String,
        portfolioListId: String?,
        userId: UUID,
        on db: any Database
    ) async throws -> Account {
        guard let account = try await resolveImportAccount(
            provider: provider,
            portfolioListId: portfolioListId,
            userId: userId,
            createIfMissing: true,
            on: db
        ) else {
            throw Abort(.internalServerError, reason: "Failed to create import account.")
        }
        return account
    }

    func requireInstrument(symbol: String, on req: Request, db: any Database) async throws -> Instrument {
        if let existing = try await Instrument.query(on: db)
            .filter(\.$symbol == symbol)
            .first()
        {
            return existing
        }

        let candidate = try await resolveInstrumentCandidate(symbol: symbol, on: req)

        let instrument = Instrument(
            conid: candidate?.conid ?? "csv-\(symbol.lowercased())",
            symbol: candidate?.symbol ?? symbol.uppercased(),
            exchange: candidate?.exchange ?? "UNKNOWN",
            currency: candidate?.currency ?? "USD",
            name: candidate?.name ?? symbol.uppercased()
        )
        try await instrument.save(on: db)
        return instrument
    }

    func resolveInstrumentCandidate(symbol: String, on req: Request) async throws -> SearchResultResponse? {
        if let local = try await Instrument.query(on: req.db)
            .filter(\.$symbol == symbol)
            .first()
        {
            return .init(
                symbol: local.symbol,
                name: local.name ?? local.symbol,
                exchange: local.exchange,
                currency: local.currency,
                conid: local.conid
            )
        }

        do {
            let results = try await req.application.marketDataService.search(query: symbol, on: req)
            return results.first { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }
        } catch {
            return nil
        }
    }

    func importAccountExternalId(provider: String, portfolioListId: String?) -> String {
        let scope = portfolioListId?.lowercased() ?? "default"
        return "csv-import-\(provider)-\(scope)"
    }

    func dedupeErrors(_ errors: [CsvImportPreviewError]) -> [CsvImportPreviewError] {
        var seen = Set<String>()
        var output: [CsvImportPreviewError] = []
        for error in errors.sorted(by: { lhs, rhs in
            if lhs.line == rhs.line {
                return lhs.message < rhs.message
            }
            return lhs.line < rhs.line
        }) {
            let key = "\(error.line)::\(error.message)"
            guard seen.insert(key).inserted else { continue }
            output.append(error)
        }
        return output
    }
}

private extension CsvImportExistingPositionKind {
    var hasImportedPosition: Bool {
        switch self {
        case .imported, .mixed:
            true
        case .none, .manual:
            false
        }
    }
}
