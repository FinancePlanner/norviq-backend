import Fluent
import Foundation
import Vapor

enum StockServiceError: Error {
    case notFound
    case invalidSymbol
    case valuationNotFound
    case valuationAlreadyExists
}

extension StockServiceError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .notFound:
            return .notFound
        case .invalidSymbol:
            return .badRequest
        case .valuationNotFound:
            return .notFound
        case .valuationAlreadyExists:
            return .conflict
        }
    }

    var reason: String {
        switch self {
        case .notFound:
            return "Stock not found."
        case .invalidSymbol:
            return "Invalid stock symbol."
        case .valuationNotFound:
            return "Stock valuation not found."
        case .valuationAlreadyExists:
            return "Stock valuation already exists."
        }
    }
}

protocol StockService: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [StockResponse]
    func get(id: UUID, userId: UUID, on db: any Database) async throws -> StockResponse
    func get(symbol: String, userId: UUID, on db: any Database) async throws -> StockResponse
    func getInsights(symbol: String, userId: UUID, on db: any Database) async throws -> StockInsightsResponse
    func getValuation(symbol: String, userId: UUID, on db: any Database) async throws
        -> StockValuationRequest
    func create(payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    func createValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuationRequest
    func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws
        -> BulkStockResponse
    func update(id: UUID, payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse
    func updateValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuationRequest
    func delete(id: UUID, userId: UUID, on db: any Database) async throws
    func sell(id: UUID, payload: SellStockRequest, userId: UUID, on db: any Database) async throws -> StockResponse
}

struct StockServiceImpl: StockService {
    let repo: any StocksRepository
    let req: Request

    func list(userId: UUID, on db: any Database) async throws -> [StockResponse] {
        let stocks = try await repo.list(userId: userId, on: db)
        return try stocks.map { try StockResponse(from: $0) }
    }

    func get(id: UUID, userId: UUID, on db: any Database) async throws -> StockResponse {
        guard let stock = try await repo.find(id: id, userId: userId, on: db) else {
            throw StockServiceError.notFound
        }
        return try StockResponse(from: stock)
    }

    func get(symbol: String, userId: UUID, on db: any Database) async throws -> StockResponse {
        guard let stock = try await repo.find(symbol: symbol, userId: userId, on: db) else {
            throw StockServiceError.notFound
        }
        return try StockResponse(from: stock)
    }

    func getInsights(symbol: String, userId: UUID, on db: any Database) async throws -> StockInsightsResponse {
        let normalizedSymbol = try validateSymbol(symbol)
        let primaryMetrics = try await req.application.marketDataService.analysis(
            symbol: normalizedSymbol,
            on: req
        )
        let primaryProfile = try? await req.application.marketDataService.profile(
            symbol: normalizedSymbol,
            on: req
        )

        let currentPrice = max(0, primaryMetrics.currentPrice ?? 0)
        let marketCap = max(0, primaryMetrics.marketCap ?? primaryProfile?.marketCapitalization ?? 0)
        let sharesOutstanding = max(
            0,
            primaryMetrics.sharesOutstanding ?? primaryProfile?.shareOutstanding ?? 0
        )
        let scenarios = makeProjectionScenarios(
            from: primaryMetrics,
            fallbackCurrentPrice: currentPrice,
            fallbackMarketCap: marketCap,
            fallbackSharesOutstanding: sharesOutstanding
        )

        let peerSymbols = try await prioritizedPeerSymbols(
            userId: userId,
            excluding: normalizedSymbol,
            on: db
        )
        var peers: [StockInsightPeerDTO] = []
        peers.reserveCapacity(peerSymbols.count)

        for peerSymbol in peerSymbols {
            let peerMetrics = try? await req.application.marketDataService.analysis(
                symbol: peerSymbol,
                on: req
            )
            let peerProfile = try? await req.application.marketDataService.profile(
                symbol: peerSymbol,
                on: req
            )
            let peerPrice = max(0, peerMetrics?.currentPrice ?? 0)
            let peerMarketCap = max(
                0,
                peerMetrics?.marketCap ?? peerProfile?.marketCapitalization ?? 0
            )
            let peerSharesOutstanding = max(
                0,
                peerMetrics?.sharesOutstanding ?? peerProfile?.shareOutstanding ?? 0
            )

            peers.append(
                StockInsightPeerDTO(
                    symbol: peerSymbol,
                    companyName: resolvedCompanyName(peerProfile?.name, symbol: peerSymbol),
                    currentPrice: peerPrice,
                    marketCap: peerMarketCap,
                    sharesOutstanding: peerSharesOutstanding
                )
            )
        }

        return StockInsightsResponse(
            generatedAt: isoTimestamp(Date()),
            symbol: normalizedSymbol,
            profile: StockInsightProfileDTO(
                symbol: normalizedSymbol,
                companyName: resolvedCompanyName(primaryProfile?.name, symbol: normalizedSymbol),
                currentPrice: currentPrice,
                marketCap: marketCap,
                sharesOutstanding: sharesOutstanding,
                metrics: comparisonMetricsMap(from: primaryMetrics),
                dcfBasePrice: primaryMetrics.dcfBasePrice,
                dcfBearPrice: primaryMetrics.dcfBearPrice,
                dcfBullPrice: primaryMetrics.dcfBullPrice
            ),
            peers: peers,
            projectionScenarios: scenarios
        )
    }

    func getValuation(symbol: String, userId: UUID, on db: any Database) async throws
        -> StockValuationRequest {
        let normalizedSymbol = try validateSymbol(symbol)
        guard try await repo.find(symbol: normalizedSymbol, userId: userId, on: db) != nil else {
            throw StockServiceError.notFound
        }
        guard let valuation = try await repo.findValuation(symbol: normalizedSymbol, userId: userId, on: db)
        else {
            throw StockServiceError.valuationNotFound
        }
        return StockValuationRequest(from: valuation)
    }

    func create(payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse {
        _ = try validateSymbol(payload.symbol)
        let stock = try await repo.create(payload: payload, userId: userId, on: db)

        try? await req.userActivityService.recordActivity(
            userId: userId,
            type: .stockAdded,
            title: stock.symbol,
            subtitle: "Added to portfolio",
            amount: stock.shares * stock.buyPrice,
            isGrowth: true,
            symbol: "plus.circle.fill",
            on: db
        )

        return try StockResponse(from: stock)
    }

    func createValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuationRequest {
        let normalizedPayload = try normalizeValuationPayload(pathSymbol: symbol, payload: payload)
        guard try await repo.find(symbol: normalizedPayload.symbol, userId: userId, on: db) != nil else {
            throw StockServiceError.notFound
        }
        if try await repo.findValuation(symbol: normalizedPayload.symbol, userId: userId, on: db) != nil {
            throw StockServiceError.valuationAlreadyExists
        }

        let valuation = try await repo.createValuation(
            payload: normalizedPayload,
            userId: userId,
            on: db
        )
        return StockValuationRequest(from: valuation)
    }

    func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws
        -> BulkStockResponse {
        let results = try await repo.bulkCreate(payloads: payloads, userId: userId, on: db)
        let created = results.filter { $0.stock != nil }.count
        let failed = results.filter { $0.error != nil }.count

        if created > 0 {
            try? await req.userActivityService.recordActivity(
                userId: userId,
                type: .stockAdded,
                title: "\(created) Stocks",
                subtitle: "Bulk imported",
                amount: nil,
                isGrowth: true,
                symbol: "arrow.down.doc.fill",
                on: db
            )
        }

        return BulkStockResponse(created: created, failed: failed, results: results)
    }

    func update(id: UUID, payload: StockRequest, userId: UUID, on db: any Database) async throws
        -> StockResponse {
        _ = try validateSymbol(payload.symbol)
        guard let stock = try await repo.update(id: id, payload: payload, userId: userId, on: db)
        else {
            throw StockServiceError.notFound
        }

        try? await req.userActivityService.recordActivity(
            userId: userId,
            type: .stockUpdated,
            title: stock.symbol,
            subtitle: "Updated holding",
            amount: stock.shares * stock.buyPrice,
            isGrowth: true,
            symbol: "pencil.circle.fill",
            on: db
        )

        return try StockResponse(from: stock)
    }

    func updateValuation(
        symbol: String,
        payload: StockValuationRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> StockValuationRequest {
        let normalizedPayload = try normalizeValuationPayload(pathSymbol: symbol, payload: payload)
        guard try await repo.find(symbol: normalizedPayload.symbol, userId: userId, on: db) != nil else {
            throw StockServiceError.notFound
        }
        guard
            let valuation = try await repo.updateValuation(
                symbol: normalizedPayload.symbol,
                payload: normalizedPayload,
                userId: userId,
                on: db
            )
        else {
            throw StockServiceError.valuationNotFound
        }
        return StockValuationRequest(from: valuation)
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws {
        let deleted = try await repo.delete(id: id, userId: userId, on: db)
        guard deleted else {
            throw StockServiceError.notFound
        }
    }

    func sell(id: UUID, payload: SellStockRequest, userId: UUID, on db: any Database) async throws -> StockResponse {
        guard let stock = try await repo.find(id: id, userId: userId, on: db) else {
            throw StockServiceError.notFound
        }

        guard payload.sharesToSell > 0 else {
            throw Abort(.badRequest, reason: "Shares to sell must be greater than 0.")
        }

        guard payload.sharesToSell <= stock.shares else {
            throw Abort(.badRequest, reason: "Cannot sell more shares than owned.")
        }

        let proceeds = payload.sharesToSell * payload.sellPrice

        return try await db.transaction { transactionDB in
            // 1. Update/Delete Stock
            if payload.sharesToSell == stock.shares {
                _ = try await repo.delete(id: id, userId: userId, on: transactionDB)
                stock.shares = 0
            } else {
                stock.shares -= payload.sharesToSell
                try await stock.save(on: transactionDB)
            }

            // 2. Find Account (needed for CashBalance)
            // We look for any account belonging to the user.
            guard let account = try await Account.query(on: transactionDB).filter(\.$userId == userId).first() else {
                throw Abort(.badRequest, reason: "No brokerage account found to deposit cash proceeds. Please create an account first.")
            }

            // 3. Update CashBalance
            let currency = "USD" // Fallback, ideally should match account/stock
            if let existingCash = try await CashBalance.query(on: transactionDB)
                .filter(\.$accountId == account.id!)
                .filter(\.$currency == currency)
                .first() {
                existingCash.balance += proceeds
                existingCash.asOf = Date()
                try await existingCash.save(on: transactionDB)
            } else {
                let newCash = CashBalance(
                    accountId: account.id!,
                    currency: currency,
                    balance: proceeds,
                    asOf: Date()
                )
                try await newCash.save(on: transactionDB)
            }

            // 4. Record Activity
            try? await req.userActivityService.recordActivity(
                userId: userId,
                type: .stockUpdated,
                title: stock.symbol,
                subtitle: "Sold \(payload.sharesToSell) shares",
                amount: proceeds,
                isGrowth: true,
                symbol: "minus.circle.fill",
                on: transactionDB
            )

            return try StockResponse(from: stock)
        }
    }

    private func validateSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw StockServiceError.invalidSymbol
        }
        return normalized.uppercased()
    }

    private func normalizeValuationPayload(pathSymbol: String, payload: StockValuationRequest) throws
        -> StockValuationRequest {
        let normalizedPathSymbol = try validateSymbol(pathSymbol)
        let normalizedBodySymbol = try validateSymbol(payload.symbol)
        guard normalizedPathSymbol == normalizedBodySymbol else {
            throw Abort(
                .badRequest,
                reason:
                    """
                    Body symbol must match the route symbol. \
                    routeRaw=\(String(reflecting: pathSymbol)) \
                    bodyRaw=\(String(reflecting: payload.symbol)) \
                    routeNormalized=\(String(reflecting: normalizedPathSymbol)) \
                    bodyNormalized=\(String(reflecting: normalizedBodySymbol))
                    """
            )
        }

        return StockValuationRequest(
            symbol: normalizedPathSymbol,
            bearCase: try normalizePriceRange(payload.bearCase, field: "bearCase"),
            baseCase: try normalizePriceRange(payload.baseCase, field: "baseCase"),
            bullCase: try normalizePriceRange(payload.bullCase, field: "bullCase"),
            rationale: normalizeOptionalText(payload.rationale),
            targetDate: try normalizeOptionalDateString(payload.targetDate)
        )
    }

    private func normalizePriceRange(_ range: PriceRange, field: String) throws -> PriceRange {
        guard range.low >= 0 else {
            throw Abort(.badRequest, reason: "\(field).low must be greater than or equal to 0.")
        }
        guard range.high >= 0 else {
            throw Abort(.badRequest, reason: "\(field).high must be greater than or equal to 0.")
        }
        guard range.low <= range.high else {
            throw Abort(.badRequest, reason: "\(field).low must be less than or equal to \(field).high.")
        }
        return range
    }

    private func normalizeOptionalText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeOptionalDateString(_ raw: String?) throws -> String? {
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
            throw Abort(.badRequest, reason: "Invalid targetDate. Expected YYYY-MM-DD.")
        }
        return formatter.string(from: value)
    }

    private func resolvedCompanyName(_ value: String?, symbol: String) -> String {
        guard let value else { return symbol }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? symbol : trimmed
    }

    private func prioritizedPeerSymbols(
        userId: UUID,
        excluding primarySymbol: String,
        on db: any Database
    ) async throws -> [String] {
        let watchlistSymbols = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)
            .all()
            .map { $0.symbol.uppercased() }

        let holdingSymbols = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)
            .all()
            .map { $0.symbol.uppercased() }

        var seen: Set<String> = [primarySymbol]
        var ordered: [String] = []
        ordered.reserveCapacity(watchlistSymbols.count + holdingSymbols.count)

        for symbol in watchlistSymbols + holdingSymbols {
            guard seen.insert(symbol).inserted else { continue }
            ordered.append(symbol)
        }
        return Array(ordered.prefix(8))
    }

    private func comparisonMetricsMap(from metrics: StockAnalysisMetricsResponse) -> [String: Double] {
        [
            "ttmPE": metrics.ttmPE,
            "forwardPE": metrics.forwardPE,
            "twoYearForwardPE": metrics.twoYearForwardPE,
            "ttmEPSGrowth": metrics.ttmEPSGrowth,
            "currentYearExpectedEPSGrowth": metrics.currentYearExpectedEPSGrowth,
            "nextYearEPSGrowth": metrics.nextYearEPSGrowth,
            "ttmRevenueGrowth": metrics.ttmRevenueGrowth,
            "currentYearExpectedRevenueGrowth": metrics.currentYearExpectedRevenueGrowth,
            "nextYearRevenueGrowth": metrics.nextYearRevenueGrowth,
            "grossMargin": metrics.grossMargin,
            "netMargin": metrics.netMargin,
            "ttmPEGRatio": metrics.ttmPEGRatio,
            "lastYearEPSGrowth": metrics.lastYearEPSGrowth,
            "ttmVsNTMEPSGrowth": metrics.ttmVsNTMEPSGrowth,
            "currentQuarterEPSGrowthVsPreviousYear": metrics.currentQuarterEPSGrowthVsPreviousYear,
            "twoYearStackExpectedEPSGrowth": metrics.twoYearStackExpectedEPSGrowth,
            "lastYearRevenueGrowth": metrics.lastYearRevenueGrowth,
            "ttmVsNTMRevenueGrowth": metrics.ttmVsNTMRevenueGrowth,
            "currentQuarterRevenueGrowthVsPreviousYear": metrics.currentQuarterRevenueGrowthVsPreviousYear,
            "twoYearStackExpectedRevenueGrowth": metrics.twoYearStackExpectedRevenueGrowth,
            "dcfFairValue": metrics.dcfBasePrice
        ].compactMapValues { value in
            guard let value else { return nil }
            return value.isFinite ? value : nil
        }
    }

    private struct ProjectionScenarioConfig {
        let kind: String
        let growthShift: Double
        let peLowShift: Double
        let peHighShift: Double
    }

    private struct FallbackProjectionScenarioConfig {
        let kind: String
        let growth: Double
        let peLow: Double
        let peHigh: Double
    }

    private func makeProjectionScenarios(
        from metrics: StockAnalysisMetricsResponse,
        fallbackCurrentPrice: Double,
        fallbackMarketCap: Double,
        fallbackSharesOutstanding: Double
    ) -> [StockInsightProjectionScenarioDTO] {
        guard
            let baseProjections = metrics.yearlyProjections,
            !baseProjections.isEmpty,
            let currentPrice = metrics.currentPrice,
            currentPrice > 0,
            let marketCap = metrics.marketCap,
            marketCap > 0,
            let sharesOutstanding = metrics.sharesOutstanding,
            sharesOutstanding > 0
        else {
            return fallbackProjectionScenarios(
                currentPrice: fallbackCurrentPrice,
                marketCap: fallbackMarketCap,
                sharesOutstanding: fallbackSharesOutstanding
            )
        }

        let baseYear = metrics.baseYear ?? ((baseProjections.first?.year ?? 2026) - 1)
        let firstProjection = baseProjections[0]
        let revenueDenominator = max(1.0 + firstProjection.revenueGrowth, 0.1)
        let incomeDenominator = max(1.0 + firstProjection.netIncomeGrowth, 0.1)
        let trailingRevenue = firstProjection.revenue / revenueDenominator
        let trailingNetIncome = firstProjection.netIncome / incomeDenominator

        let peLowBase = max((metrics.forwardPE ?? 20) * 0.9, 8)
        let peHighBase = max((metrics.ttmPE ?? peLowBase) * 1.05, peLowBase + 1)
        let terminalGrowthRate = metrics.terminalGrowthRate ?? 0.025
        let terminalMargin = max(metrics.terminalMargin ?? 0.22, 0.08)
        let baseNetMargin = max(metrics.netMargin ?? firstProjection.netMargin, 0.05)

        let config: [ProjectionScenarioConfig] = [
            ProjectionScenarioConfig(kind: "bear", growthShift: -0.03, peLowShift: -2, peHighShift: -2),
            ProjectionScenarioConfig(kind: "base", growthShift: 0, peLowShift: 0, peHighShift: 0),
            ProjectionScenarioConfig(kind: "bull", growthShift: 0.03, peLowShift: 2, peHighShift: 2)
        ]

        return config.map { item in
            var years: [StockInsightProjectionYearDTO] = []
            years.reserveCapacity(baseProjections.count + 1)

            let trailingEPS = trailingNetIncome / sharesOutstanding
            years.append(
                StockInsightProjectionYearDTO(
                    year: baseYear,
                    revenue: trailingRevenue,
                    revenueGrowth: metrics.ttmRevenueGrowth ?? 0,
                    netIncome: trailingNetIncome,
                    netIncomeGrowth: metrics.ttmEPSGrowth ?? 0,
                    netMargin: baseNetMargin,
                    eps: trailingEPS,
                    peLowEstimate: peLowBase,
                    peHighEstimate: peHighBase,
                    sharePriceLow: trailingEPS * peLowBase,
                    sharePriceHigh: trailingEPS * peHighBase,
                    cagrLow: nil,
                    cagrHigh: nil
                )
            )

            var runningRevenue = trailingRevenue
            var runningNetIncome = trailingNetIncome

            for (index, projection) in baseProjections.enumerated() {
                let revenueGrowth = max(projection.revenueGrowth + item.growthShift, terminalGrowthRate)
                let netIncomeGrowth = max(projection.netIncomeGrowth + item.growthShift, terminalGrowthRate)
                runningRevenue = runningRevenue * (1 + revenueGrowth)
                runningNetIncome = runningNetIncome * (1 + netIncomeGrowth)

                let margin = min(
                    max(baseNetMargin + Double(index + 1) * 0.01, 0.03),
                    max(terminalMargin, baseNetMargin)
                )
                let actualNetIncome = runningRevenue * margin
                let eps = actualNetIncome / sharesOutstanding
                let peLow = max(8, peLowBase + item.peLowShift)
                let peHigh = max(peLow + 1, peHighBase + item.peHighShift)
                let priceLow = eps * peLow
                let priceHigh = eps * peHigh

                let yearsForward = Double(index + 1)
                let cagrLow = pow(priceLow / currentPrice, 1.0 / yearsForward) - 1
                let cagrHigh = pow(priceHigh / currentPrice, 1.0 / yearsForward) - 1

                years.append(
                    StockInsightProjectionYearDTO(
                        year: projection.year,
                        revenue: runningRevenue,
                        revenueGrowth: revenueGrowth,
                        netIncome: actualNetIncome,
                        netIncomeGrowth: netIncomeGrowth,
                        netMargin: margin,
                        eps: eps,
                        peLowEstimate: peLow,
                        peHighEstimate: peHigh,
                        sharePriceLow: priceLow,
                        sharePriceHigh: priceHigh,
                        cagrLow: cagrLow,
                        cagrHigh: cagrHigh
                    )
                )
            }

            return StockInsightProjectionScenarioDTO(kind: item.kind, years: years)
        }
    }

    private func fallbackProjectionScenarios(
        currentPrice: Double,
        marketCap: Double,
        sharesOutstanding: Double
    ) -> [StockInsightProjectionScenarioDTO] {
        let basePrice = max(currentPrice, 1)
        let baseShares = max(sharesOutstanding, 1)
        let baseRevenue = max(marketCap * 0.22, 1_000_000)
        let baseNetMargin = 0.12
        let baseNetIncome = baseRevenue * baseNetMargin
        let startYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let config: [FallbackProjectionScenarioConfig] = [
            FallbackProjectionScenarioConfig(kind: "bear", growth: 0.03, peLow: 12, peHigh: 15),
            FallbackProjectionScenarioConfig(kind: "base", growth: 0.07, peLow: 16, peHigh: 20),
            FallbackProjectionScenarioConfig(kind: "bull", growth: 0.11, peLow: 20, peHigh: 25)
        ]

        return config.map { scenario in
            var years: [StockInsightProjectionYearDTO] = []
            var revenue = baseRevenue
            var netIncome = baseNetIncome
            years.reserveCapacity(4)

            for offset in 1...4 {
                revenue *= (1 + scenario.growth)
                netIncome *= (1 + scenario.growth + 0.01)
                let margin = min(max(netIncome / revenue, 0.06), 0.35)
                let eps = netIncome / baseShares
                let low = eps * scenario.peLow
                let high = eps * scenario.peHigh
                let yearsForward = Double(offset)
                let cagrLow = pow(low / basePrice, 1.0 / yearsForward) - 1
                let cagrHigh = pow(high / basePrice, 1.0 / yearsForward) - 1

                years.append(
                    StockInsightProjectionYearDTO(
                        year: startYear + offset,
                        revenue: revenue,
                        revenueGrowth: scenario.growth,
                        netIncome: netIncome,
                        netIncomeGrowth: scenario.growth + 0.01,
                        netMargin: margin,
                        eps: eps,
                        peLowEstimate: scenario.peLow,
                        peHighEstimate: scenario.peHigh,
                        sharePriceLow: low,
                        sharePriceHigh: high,
                        cagrLow: cagrLow,
                        cagrHigh: cagrHigh
                    )
                )
            }
            return StockInsightProjectionScenarioDTO(kind: scenario.kind, years: years)
        }
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension StockResponse {
    init(from model: Stock) throws {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Stock id missing")
        }

        self.init(
            id: id.uuidString,
            symbol: model.symbol,
            shares: model.shares,
            buyPrice: model.buyPrice,
            buyDate: Self.formatISODateOnly(model.buyDate),
            notes: model.notes,
            category: model.category
        )
    }

    private static func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension StockValuationRequest {
    init(from model: StockValuation) {
        self.init(
            symbol: model.symbol,
            bearCase: PriceRange(low: model.bearLow, high: model.bearHigh),
            baseCase: PriceRange(low: model.baseLow, high: model.baseHigh),
            bullCase: PriceRange(low: model.bullLow, high: model.bullHigh),
            rationale: model.rationale,
            targetDate: Self.formatISODateOnly(model.targetDate)
        )
    }

    private static func formatISODateOnly(_ date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
