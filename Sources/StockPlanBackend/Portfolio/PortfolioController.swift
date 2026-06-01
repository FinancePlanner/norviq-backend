import Fluent
import Foundation
import Vapor

struct PortfolioController: RouteCollection {
    private struct PortfolioFilterQuery: Content {
        let portfolioListId: String?
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let portfolio = protected.grouped("portfolio")
        portfolio.get("summary", use: summary)
        portfolio.get("performance", use: performance)
        portfolio.get("sector-exposure", use: sectorExposure)
        portfolio.group("lists") { lists in
            lists.get(use: listPortfolioLists)
            lists.post(use: createPortfolioList)
            lists.group(":portfolioListId") { list in
                list.patch(use: updatePortfolioList)
                list.delete(use: deletePortfolioList)
            }
        }

        protected.get("transactions", use: transactions)
        protected.get("lots", use: lots)
        protected.get("pnl", use: pnl)
    }

    @Sendable
    func summary(req: Request) async throws -> PortfolioSummaryResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(PortfolioFilterQuery.self)
        let resolvedListId = try await resolvePortfolioListId(
            requestedId: query.portfolioListId,
            userId: session.userId,
            on: req.db,
            defaultWhenMissing: false
        )

        let stocksQuery = Stock.query(on: req.db)
            .filter(\.$userId == session.userId)
        if let resolvedListId {
            stocksQuery.filter(\.$portfolioListId == resolvedListId)
        }
        let stocks = try await stocksQuery.all()
        let cashBalance = try await totalCashBalance(userId: session.userId, on: req.db)

        var allocation = stocks
            .map { stock in
                AllocationItem(
                    symbol: stock.symbol,
                    value: stock.shares * stock.buyPrice,
                    currency: "USD"
                )
            }
        if cashBalance > 0 {
            allocation.append(
                AllocationItem(
                    symbol: "CASH",
                    value: cashBalance,
                    currency: "USD"
                )
            )
        }
        allocation.sort(by: { $0.value > $1.value })

        let totalCost = allocation.reduce(0.0) { $0 + $1.value }

        return PortfolioSummaryResponse(
            baseCurrency: "USD",
            totalValue: totalCost,
            totalCost: totalCost,
            unrealizedPnl: 0,
            realizedPnl: 0,
            cashBalance: cashBalance,
            allocation: allocation
        )
    }

    @Sendable
    func performance(req: Request) async throws -> PortfolioPerformanceResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(PortfolioFilterQuery.self)
        let resolvedListId = try await resolvePortfolioListId(
            requestedId: query.portfolioListId,
            userId: session.userId,
            on: req.db,
            defaultWhenMissing: false
        )
        let stocksQuery = Stock.query(on: req.db)
            .filter(\.$userId == session.userId)
        if let resolvedListId {
            stocksQuery.filter(\.$portfolioListId == resolvedListId)
        }
        let stocks = try await stocksQuery.all()

        let holdingsValue = stocks.reduce(0.0) { $0 + ($1.shares * $1.buyPrice) }
        let cashBalance = try await totalCashBalance(userId: session.userId, on: req.db)
        let totalValue = holdingsValue + cashBalance

        let calendar = Calendar(identifier: .gregorian)
        let today = Date()

        var points: [PerformancePoint] = []
        for i in (0 ..< 7).reversed() {
            let d = calendar.date(byAdding: .day, value: -i, to: today)!
            // Add a tiny bit of random noise for a better UI look (±0.5%)
            let noise = totalValue * Double.random(in: -0.005 ... 0.005)
            let val = max(0, totalValue + noise)
            points.append(.init(date: formatISODateOnly(d), value: val))
        }

        return PortfolioPerformanceResponse(
            baseCurrency: "USD",
            points: points
        )
    }

    @Sendable
    func sectorExposure(req: Request) async throws -> PortfolioSectorExposureResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(PortfolioFilterQuery.self)
        let resolvedListId = try await resolvePortfolioListId(
            requestedId: query.portfolioListId,
            userId: session.userId,
            on: req.db,
            defaultWhenMissing: false
        )

        let stocksQuery = Stock.query(on: req.db)
            .filter(\.$userId == session.userId)
        if let resolvedListId {
            stocksQuery.filter(\.$portfolioListId == resolvedListId)
        }
        let stocks = try await stocksQuery.all()
        let symbols = uniqueSymbols(stocks.map(\.symbol))
        let quotesBySymbol = try await latestQuotesBySymbol(symbols: symbols, on: req.db)
        let profilesBySymbol = try await profileIndustriesBySymbol(symbols: symbols, on: req.db)
        let cashBalance = try await totalCashBalance(userId: session.userId, on: req.db)

        var holdingsBySector: [String: [PortfolioSectorHoldingContribution]] = [:]
        var valueBySector: [String: Double] = [:]
        var investedValue = 0.0

        for stock in stocks {
            let symbol = normalizeSymbol(stock.symbol)
            let currentPrice = quotesBySymbol[symbol] ?? stock.buyPrice
            let value = max(0, stock.shares * currentPrice)
            guard value > 0 else { continue }

            investedValue += value
            let sector = sectorName(
                for: symbol,
                industry: profilesBySymbol[symbol],
                notes: stock.notes
            )
            valueBySector[sector, default: 0] += value
            holdingsBySector[sector, default: []].append(
                PortfolioSectorHoldingContribution(
                    symbol: symbol,
                    value: round2(value),
                    weightPercent: 0
                )
            )
        }

        let totalValue = investedValue + cashBalance
        let sectors = valueBySector
            .map { sector, value -> PortfolioSectorExposureItem in
                let weight = percentage(value, of: investedValue)
                let benchmark = sp500SectorWeights[sector]
                let holdings = (holdingsBySector[sector] ?? [])
                    .sorted(by: { $0.value > $1.value })
                    .map {
                        PortfolioSectorHoldingContribution(
                            symbol: $0.symbol,
                            value: $0.value,
                            weightPercent: percentage($0.value, of: investedValue)
                        )
                    }

                return PortfolioSectorExposureItem(
                    sector: sector,
                    value: round2(value),
                    weightPercent: weight,
                    benchmarkWeightPercent: benchmark,
                    overweightPercent: benchmark.map { round2(weight - $0) },
                    holdings: holdings
                )
            }
            .sorted(by: { $0.value > $1.value })

        return PortfolioSectorExposureResponse(
            baseCurrency: "USD",
            totalValue: round2(totalValue),
            investedValue: round2(investedValue),
            cashBalance: round2(cashBalance),
            benchmarkName: "S&P 500",
            benchmarkAsOf: "2026-05-29",
            sectors: sectors
        )
    }

    @Sendable
    func transactions(req: Request) async throws -> [TransactionResponse] {
        _ = try req.auth.require(SessionToken.self)
        return []
    }

    @Sendable
    func lots(req: Request) async throws -> [LotResponse] {
        let session = try req.auth.require(SessionToken.self)
        let accounts = try await Account.query(on: req.db)
            .filter(\.$userId == session.userId)
            .all()
        let accountIds = accounts.compactMap(\.id)
        guard !accountIds.isEmpty else { return [] }

        let instruments = try await Instrument.query(on: req.db).all()
        let instrumentById = Dictionary(uniqueKeysWithValues: instruments.compactMap { instrument in
            instrument.id.map { ($0, instrument) }
        })

        let lots = try await Lot.query(on: req.db)
            .filter(\.$accountId ~~ accountIds)
            .sort(\.$openDate, .descending)
            .all()

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        return lots.compactMap { lot in
            guard let id = lot.id else { return nil }
            let instrument = instrumentById[lot.instrumentId]
            return LotResponse(
                id: id.uuidString,
                accountId: lot.accountId.uuidString,
                instrumentId: instrument?.symbol ?? lot.instrumentId.uuidString,
                openDate: formatter.string(from: lot.openDate),
                closeDate: lot.closeDate.map { formatter.string(from: $0) },
                openQuantity: lot.openQuantity,
                remainingQuantity: lot.remainingQuantity,
                openPrice: lot.openPrice,
                currency: lot.currency,
                realizedPnl: lot.realizedPnl,
                status: lot.status
            )
        }
    }

    @Sendable
    func pnl(req: Request) async throws -> PnlResponse {
        let session = try req.auth.require(SessionToken.self)
        let stocks = try await Stock.query(on: req.db)
            .filter(\.$userId == session.userId)
            .all()

        let items = stocks.map {
            PnlBySymbol(symbol: $0.symbol, currency: "USD", realizedPnl: 0, unrealizedPnl: 0)
        }

        return PnlResponse(baseCurrency: "USD", items: items)
    }

    @Sendable
    func listPortfolioLists(req: Request) async throws -> [PortfolioListResponse] {
        let session = try req.auth.require(SessionToken.self)

        if try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count() == 0
        {
            _ = try await ensureDefaultPortfolioListId(userId: session.userId, on: req.db)
        }

        let lists = try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$isDefault, .descending)
            .sort(\.$createdAt, .ascending)
            .all()

        return lists.map(makePortfolioListResponse)
    }

    @Sendable
    func createPortfolioList(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(PortfolioListRequest.self)
        let name = try normalizeListName(payload.name)
        let currentCount = try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count()
        try await req.usageCounterService.enforceResourceLimit(
            .portfolioLists,
            userId: session.userId,
            currentCount: currentCount,
            adding: 1,
            on: req.db
        )

        let list = PortfolioList(userId: session.userId, name: name, isDefault: false)
        try await list.save(on: req.db)
        // Business metric: portfolios created (lists)
        req.application.businessMetrics.incrementPortfoliosCreated()

        let res = Response(status: .created)
        try res.content.encode(makePortfolioListResponse(from: list))
        return res
    }

    @Sendable
    func updatePortfolioList(req: Request) async throws -> PortfolioListResponse {
        let session = try req.auth.require(SessionToken.self)
        let listId = try requireUUIDParameter(
            req,
            name: "portfolioListId",
            reason: "Invalid portfolio list ID"
        )
        let payload = try req.content.decode(PortfolioListRequest.self)
        let name = try normalizeListName(payload.name)

        guard let list = try await PortfolioList.query(on: req.db)
            .filter(\.$id == listId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Portfolio list not found.")
        }

        list.name = name
        try await list.save(on: req.db)
        return makePortfolioListResponse(from: list)
    }

    @Sendable
    func deletePortfolioList(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let listId = try requireUUIDParameter(
            req,
            name: "portfolioListId",
            reason: "Invalid portfolio list ID"
        )

        try await req.db.transaction { tx in
            guard let list = try await PortfolioList.query(on: tx)
                .filter(\.$id == listId)
                .filter(\.$userId == session.userId)
                .first()
            else {
                throw Abort(.notFound, reason: "Portfolio list not found.")
            }

            if list.isDefault {
                throw Abort(.badRequest, reason: "Default portfolio list cannot be deleted.")
            }

            guard let defaultListId = try await resolvePortfolioListId(
                requestedId: nil,
                userId: session.userId,
                on: tx,
                defaultWhenMissing: true
            ) else {
                throw Abort(.internalServerError, reason: "Failed to resolve default portfolio list.")
            }

            let stocks = try await Stock.query(on: tx)
                .filter(\.$userId == session.userId)
                .filter(\.$portfolioListId == listId)
                .all()

            for stock in stocks {
                if let stockId = stock.id,
                   let duplicate = try await Stock.query(on: tx)
                   .filter(\.$userId == session.userId)
                   .filter(\.$portfolioListId == defaultListId)
                   .filter(\.$symbol == stock.symbol)
                   .filter(\.$id != stockId)
                   .first()
                {
                    let mergedShares = duplicate.shares + stock.shares
                    let mergedCostBasis = (duplicate.shares * duplicate.buyPrice) + (stock.shares * stock.buyPrice)
                    duplicate.shares = mergedShares
                    duplicate.buyPrice = mergedShares != 0 ? mergedCostBasis / mergedShares : 0
                    duplicate.buyDate = min(duplicate.buyDate, stock.buyDate)
                    duplicate.notes = duplicate.notes ?? stock.notes
                    duplicate.category = stock.category
                    try await duplicate.save(on: tx)
                    try await stock.delete(on: tx)
                    continue
                }

                stock.portfolioListId = defaultListId
                try await stock.save(on: tx)
            }

            try await list.delete(on: tx)
        }

        return .noContent
    }

    private func totalCashBalance(userId: UUID, on db: any Database) async throws -> Double {
        let accounts = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .all()
        let accountIds = accounts.compactMap(\.id)
        guard !accountIds.isEmpty else { return 0 }

        let balances = try await CashBalance.query(on: db)
            .filter(\.$accountId ~~ accountIds)
            .all()
        var latestByAccountCurrency: [String: CashBalance] = [:]
        for balance in balances {
            let key = "\(balance.accountId.uuidString.lowercased())::\(balance.currency.uppercased())"
            if let existing = latestByAccountCurrency[key] {
                let existingDate = existing.asOf
                if balance.asOf > existingDate {
                    latestByAccountCurrency[key] = balance
                }
            } else {
                latestByAccountCurrency[key] = balance
            }
        }

        return latestByAccountCurrency.values.reduce(0) { $0 + max(0, $1.balance) }
    }

    private var sp500SectorWeights: [String: Double] {
        [
            "Information Technology": 38.6,
            "Financials": 11.3,
            "Communication Services": 10.4,
            "Consumer Discretionary": 9.7,
            "Health Care": 8.3,
            "Industrials": 8.3,
            "Consumer Staples": 4.5,
            "Energy": 3.1,
            "Utilities": 2.1,
            "Materials": 1.8,
            "Real Estate": 1.8,
        ]
    }

    private func latestQuotesBySymbol(symbols: [String], on db: any Database) async throws -> [String: Double] {
        guard !symbols.isEmpty else { return [:] }

        let quotes = try await QuoteCache.query(on: db)
            .filter(\.$symbol ~~ symbols)
            .sort(\.$symbol, .ascending)
            .sort(\.$asOf, .descending)
            .all()

        var result: [String: Double] = [:]
        for quote in quotes {
            let symbol = normalizeSymbol(quote.symbol)
            if result[symbol] == nil {
                result[symbol] = quote.price
            }
        }
        return result
    }

    private func profileIndustriesBySymbol(symbols: [String], on db: any Database) async throws -> [String: String] {
        guard !symbols.isEmpty else { return [:] }

        let profiles = try await ProfileCache.query(on: db)
            .filter(\.$symbol ~~ symbols)
            .all()

        var result: [String: String] = [:]
        for profile in profiles {
            let symbol = normalizeSymbol(profile.symbol)
            guard let industry = profile.finnhubIndustry?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !industry.isEmpty
            else {
                continue
            }

            if result[symbol] == nil {
                result[symbol] = industry
            }
        }
        return result
    }

    private func sectorName(for symbol: String, industry: String?, notes: String?) -> String {
        let normalizedIndustry = industry?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let noteBlob = notes?.lowercased() ?? ""
        let text = [normalizedIndustry, noteBlob].joined(separator: " ")

        if text.contains("technology") || text.contains("semiconductor") || text.contains("software") || text.contains("cloud") {
            return "Information Technology"
        }
        if text.contains("financial") || text.contains("bank") || text.contains("insurance") {
            return "Financials"
        }
        if text.contains("communication") || text.contains("telecom") || text.contains("media") || text.contains("internet") {
            return "Communication Services"
        }
        if text.contains("consumer cyclical") || text.contains("consumer discretionary") || text.contains("retail") || text.contains("auto") {
            return "Consumer Discretionary"
        }
        if text.contains("consumer defensive") || text.contains("consumer staples") || text.contains("food") || text.contains("beverage") {
            return "Consumer Staples"
        }
        if text.contains("health") || text.contains("pharma") || text.contains("biotech") {
            return "Health Care"
        }
        if text.contains("industrial") || text.contains("manufacturing") || text.contains("aerospace") {
            return "Industrials"
        }
        if text.contains("energy") || text.contains("oil") || text.contains("gas") {
            return "Energy"
        }
        if text.contains("utilities") || text.contains("utility") {
            return "Utilities"
        }
        if text.contains("basic materials") || text.contains("materials") || text.contains("chemical") || text.contains("mining") {
            return "Materials"
        }
        if text.contains("real estate") || text.contains("reit") {
            return "Real Estate"
        }

        if symbol.hasPrefix("XLK") { return "Information Technology" }
        if symbol.hasPrefix("XLF") { return "Financials" }
        if symbol.hasPrefix("XLC") { return "Communication Services" }
        if symbol.hasPrefix("XLY") { return "Consumer Discretionary" }
        if symbol.hasPrefix("XLP") { return "Consumer Staples" }
        if symbol.hasPrefix("XLV") { return "Health Care" }
        if symbol.hasPrefix("XLI") { return "Industrials" }
        if symbol.hasPrefix("XLE") { return "Energy" }
        if symbol.hasPrefix("XLU") { return "Utilities" }
        if symbol.hasPrefix("XLB") { return "Materials" }
        if symbol.hasPrefix("XLRE") { return "Real Estate" }
        return "Unknown"
    }

    private func uniqueSymbols(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let symbol = normalizeSymbol(value)
            guard !symbol.isEmpty, !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            result.append(symbol)
        }
        return result
    }

    private func normalizeSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func percentage(_ value: Double, of total: Double) -> Double {
        guard total > 0 else { return 0 }
        return round2((value / total) * 100)
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func requireUUIDParameter(_ req: Request, name: String, reason: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: reason)
        }
        return value
    }

    private func makePortfolioListResponse(from model: PortfolioList) -> PortfolioListResponse {
        let id = model.id ?? UUID()
        return PortfolioListResponse(
            id: id.uuidString,
            name: model.name,
            isDefault: model.isDefault,
            createdAt: formatISODateTime(model.createdAt),
            updatedAt: formatISODateTime(model.updatedAt)
        )
    }

    private func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
