import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol RebalancingServicing: Sendable {
    func models(portfolioId: UUID, userId: UUID, req: Request) async throws -> [AllocationModel]
    func createModel(
        portfolioId: UUID,
        userId: UUID,
        payload: AllocationModelUpsertRequest,
        req: Request
    ) async throws -> AllocationModel
    func updateModel(
        portfolioId: UUID,
        modelId: UUID,
        userId: UUID,
        payload: AllocationModelUpsertRequest,
        req: Request
    ) async throws -> AllocationModel
    func activateModel(portfolioId: UUID, modelId: UUID, userId: UUID, req: Request) async throws -> AllocationModel
    func copyModel(
        portfolioId: UUID,
        modelId: UUID,
        userId: UUID,
        payload: AllocationModelBulkCopyRequest,
        req: Request
    ) async throws -> AllocationModelBulkCopyResult
    func overview(portfolioId: UUID, userId: UUID, req: Request) async throws -> RebalancingOverview
    func simulate(
        portfolioId: UUID,
        userId: UUID,
        payload: RebalancingSimulationRequest,
        req: Request
    ) async throws -> RebalancingSimulation
    func createPlan(
        portfolioId: UUID,
        userId: UUID,
        payload: RebalancePlanCreateRequest,
        req: Request
    ) async throws -> RebalancePlan
    func plans(portfolioId: UUID, userId: UUID, req: Request) async throws -> [RebalancePlan]
    func transitionPlan(
        portfolioId: UUID,
        planId: UUID,
        userId: UUID,
        status: RebalancePlanStatus,
        note: String?,
        req: Request
    ) async throws -> RebalancePlan
    func history(portfolioId: UUID, userId: UUID, req: Request) async throws -> RebalancingHistorySummary
    func alerts(userId: UUID, req: Request) async throws -> [RebalancingAlert]
    func acknowledge(alertId: UUID, userId: UUID, req: Request) async throws -> RebalancingAlert
    func preferences(portfolioId: UUID, userId: UUID, req: Request) async throws -> RebalancingNotificationPreferences
    func updatePreferences(
        portfolioId: UUID,
        userId: UUID,
        payload: UpdateRebalancingNotificationPreferencesRequest,
        req: Request
    ) async throws -> RebalancingNotificationPreferences
    func dashboard(userId: UUID, req: Request) async throws -> RebalancingDashboardSummary
}

struct DefaultRebalancingService: RebalancingServicing {
    private let engine = RebalancingEngine()

    func models(portfolioId: UUID, userId: UUID, req: Request) async throws -> [AllocationModel] {
        _ = try await access(portfolioId, userId: userId, req: req)
        let records = try await AllocationModelRecord.query(on: req.db)
            .filter(\.$portfolioId == portfolioId)
            .sort(\.$isActive, .descending)
            .sort(\.$createdAt, .ascending)
            .all()
        var result = [AllocationModel]()
        for record in records {
            try await result.append(makeModel(record, on: req.db))
        }
        return result
    }

    func createModel(
        portfolioId: UUID,
        userId: UUID,
        payload: AllocationModelUpsertRequest,
        req: Request
    ) async throws -> AllocationModel {
        let context = try await access(portfolioId, userId: userId, editing: true, req: req)
        try validate(payload, portfolioId: portfolioId, baseCurrency: context.portfolio.baseCurrency)

        let recordId = UUID()
        try await req.db.transaction { database in
            if payload.activate {
                try await deactivateModels(portfolioId: portfolioId, except: nil, on: database)
            }
            let record = AllocationModelRecord(
                id: recordId,
                portfolioId: portfolioId,
                createdByUserId: userId,
                name: normalizedName(payload.name),
                groupingMode: payload.groupingMode.rawValue,
                isActive: payload.activate,
                baseCurrency: context.portfolio.baseCurrency,
                defaultTargetThresholdBasisPoints: payload.defaultTargetThresholdBasisPoints,
                totalThresholdBasisPoints: payload.totalThresholdBasisPoints,
                fractionalSharesEnabled: payload.fractionalSharesEnabled,
                quantityIncrement: payload.fractionalSharesEnabled ? payload.quantityIncrement : 1,
                minimumTradeAmount: payload.minimumTradeAmount,
                flatFee: payload.flatFee,
                variableFeeBasisPoints: payload.variableFeeBasisPoints
            )
            try await record.create(on: database)
            try await replaceTargets(modelId: recordId, buckets: payload.buckets, on: database)
        }
        guard let record = try await AllocationModelRecord.find(recordId, on: req.db) else {
            throw Abort(.internalServerError, reason: "Allocation model was not created.")
        }
        return try await makeModel(record, on: req.db)
    }

    func updateModel(
        portfolioId: UUID,
        modelId: UUID,
        userId: UUID,
        payload: AllocationModelUpsertRequest,
        req: Request
    ) async throws -> AllocationModel {
        let context = try await access(portfolioId, userId: userId, editing: true, req: req)
        try validate(payload, portfolioId: portfolioId, baseCurrency: context.portfolio.baseCurrency)
        try await req.db.transaction { database in
            guard let record = try await AllocationModelRecord.query(on: database)
                .filter(\.$id == modelId)
                .filter(\.$portfolioId == portfolioId)
                .first()
            else { throw Abort(.notFound, reason: "Allocation model not found.") }
            guard payload.expectedRevision == record.revision else {
                throw Abort(.conflict, reason: "Allocation model changed. Reload before saving.")
            }
            if payload.activate {
                try await deactivateModels(portfolioId: portfolioId, except: modelId, on: database)
            }
            record.name = normalizedName(payload.name)
            record.groupingMode = payload.groupingMode.rawValue
            record.isActive = payload.activate
            record.revision += 1
            record.defaultTargetThresholdBasisPoints = payload.defaultTargetThresholdBasisPoints
            record.totalThresholdBasisPoints = payload.totalThresholdBasisPoints
            record.fractionalSharesEnabled = payload.fractionalSharesEnabled
            record.quantityIncrement = payload.fractionalSharesEnabled ? payload.quantityIncrement : 1
            record.minimumTradeAmount = payload.minimumTradeAmount
            record.flatFee = payload.flatFee
            record.variableFeeBasisPoints = payload.variableFeeBasisPoints
            try await record.save(on: database)
            try await AllocationLeafRecord.query(on: database).filter(\.$modelId == modelId).delete()
            try await AllocationBucketRecord.query(on: database).filter(\.$modelId == modelId).delete()
            try await replaceTargets(modelId: modelId, buckets: payload.buckets, on: database)
            try await resolveAlerts(modelId: modelId, on: database)
        }
        guard let record = try await AllocationModelRecord.find(modelId, on: req.db) else {
            throw Abort(.notFound)
        }
        return try await makeModel(record, on: req.db)
    }

    func activateModel(portfolioId: UUID, modelId: UUID, userId: UUID, req: Request) async throws -> AllocationModel {
        _ = try await access(portfolioId, userId: userId, editing: true, req: req)
        try await req.db.transaction { database in
            guard let record = try await AllocationModelRecord.query(on: database)
                .filter(\.$id == modelId)
                .filter(\.$portfolioId == portfolioId)
                .first()
            else { throw Abort(.notFound, reason: "Allocation model not found.") }
            try await deactivateModels(portfolioId: portfolioId, except: modelId, on: database)
            record.isActive = true
            record.revision += 1
            try await record.save(on: database)
            try await resolveAlerts(modelId: modelId, on: database)
        }
        guard let record = try await AllocationModelRecord.find(modelId, on: req.db) else {
            throw Abort(.notFound)
        }
        return try await makeModel(record, on: req.db)
    }

    func copyModel(
        portfolioId: UUID,
        modelId: UUID,
        userId: UUID,
        payload: AllocationModelBulkCopyRequest,
        req: Request
    ) async throws -> AllocationModelBulkCopyResult {
        _ = try await access(portfolioId, userId: userId, req: req)
        guard let sourceRecord = try await AllocationModelRecord.query(on: req.db)
            .filter(\.$id == modelId)
            .filter(\.$portfolioId == portfolioId)
            .first()
        else { throw Abort(.notFound, reason: "Allocation model not found.") }
        let source = try await makeModel(sourceRecord, on: req.db)
        let destinationIds = try payload.destinationPortfolioIds.map { raw -> UUID in
            guard let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "Invalid destination portfolio id: \(raw)")
            }
            return id
        }
        guard !destinationIds.isEmpty, Set(destinationIds).count == destinationIds.count else {
            throw Abort(.badRequest, reason: "Destination portfolios must be unique and non-empty.")
        }
        var created = [AllocationModel]()
        var warnings = [RebalancingValuationWarning]()
        for destinationId in destinationIds {
            guard destinationId != portfolioId else {
                throw Abort(.badRequest, reason: "The source portfolio cannot be a copy destination.")
            }
            let destination = try await access(destinationId, userId: userId, editing: true, req: req).portfolio
            if destination.baseCurrency != source.baseCurrency {
                warnings.append(.init(
                    code: "base_currency_changed",
                    message: "\(destination.name) uses \(destination.baseCurrency); target percentages were copied without currency amounts."
                ))
            }
            try await created.append(createModel(
                portfolioId: destinationId,
                userId: userId,
                payload: AllocationModelUpsertRequest(
                    name: source.name,
                    groupingMode: source.groupingMode,
                    activate: payload.activate,
                    defaultTargetThresholdBasisPoints: source.defaultTargetThresholdBasisPoints,
                    totalThresholdBasisPoints: source.totalThresholdBasisPoints,
                    fractionalSharesEnabled: source.fractionalSharesEnabled,
                    quantityIncrement: source.quantityIncrement,
                    minimumTradeAmount: source.minimumTradeAmount,
                    flatFee: source.flatFee,
                    variableFeeBasisPoints: source.variableFeeBasisPoints,
                    buckets: source.buckets
                ),
                req: req
            ))
        }
        return .init(models: created, warnings: warnings)
    }

    func overview(portfolioId: UUID, userId: UUID, req: Request) async throws -> RebalancingOverview {
        let context = try await access(portfolioId, userId: userId, req: req)
        let modelRecord = try await activeModel(portfolioId: portfolioId, on: req.db)
        let model = try await modelRecord.asyncMap { try await makeModel($0, on: req.db) }
        let snapshot = try await valuation(
            portfolioId: portfolioId,
            dataOwnerUserId: context.portfolio.userId,
            baseCurrency: context.portfolio.baseCurrency,
            model: model,
            req: req
        )
        let openCount = try await RebalancingAlertRecord.query(on: req.db)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$userId == userId)
            .filter(\.$status != RebalancingAlertStatus.resolved.rawValue)
            .count()
        return try engine.overview(
            portfolioId: portfolioId.uuidString,
            model: model,
            snapshot: snapshot,
            openAlertCount: openCount
        )
    }

    func simulate(
        portfolioId: UUID,
        userId: UUID,
        payload: RebalancingSimulationRequest,
        req: Request
    ) async throws -> RebalancingSimulation {
        let context = try await access(portfolioId, userId: userId, req: req)
        guard let modelId = UUID(uuidString: payload.modelId),
              let record = try await AllocationModelRecord.query(on: req.db)
              .filter(\.$id == modelId)
              .filter(\.$portfolioId == portfolioId)
              .first()
        else { throw Abort(.notFound, reason: "Allocation model not found.") }
        let model = try await makeModel(record, on: req.db)
        let snapshot = try await valuation(
            portfolioId: portfolioId,
            dataOwnerUserId: context.portfolio.userId,
            baseCurrency: context.portfolio.baseCurrency,
            model: model,
            req: req
        )
        guard snapshot.priceQuality != .incomplete else {
            throw Abort(.serviceUnavailable, reason: "Simulation requires current prices and exchange rates for every target.")
        }
        do {
            return try engine.simulate(
                portfolioId: portfolioId.uuidString,
                model: model,
                request: payload,
                snapshot: snapshot
            )
        } catch {
            throw mapEngineError(error)
        }
    }

    func createPlan(
        portfolioId: UUID,
        userId: UUID,
        payload: RebalancePlanCreateRequest,
        req: Request
    ) async throws -> RebalancePlan {
        _ = try await access(portfolioId, userId: userId, editing: true, req: req)
        let simulation = try await simulate(portfolioId: portfolioId, userId: userId, payload: payload.simulation, req: req)
        guard let modelId = UUID(uuidString: simulation.modelId) else {
            throw Abort(.internalServerError)
        }
        let record = RebalancePlanRecord()
        record.id = UUID()
        record.portfolioId = portfolioId
        record.modelId = modelId
        record.createdByUserId = userId
        record.modelRevision = simulation.modelRevision
        record.name = payload.name.flatMap(optionalNormalizedName)
        record.status = RebalancePlanStatus.draft.rawValue
        record.baseCurrency = simulation.baseCurrency
        record.driftBeforeBasisPoints = simulation.driftBeforeBasisPoints
        record.driftAfterBasisPoints = simulation.driftAfterBasisPoints
        record.totalValue = simulation.totalValueBefore
        record.estimatedFees = simulation.estimatedFees
        record.estimatedRealizedGainLoss = simulation.estimatedRealizedGainLoss
        record.simulationJSON = try encode(simulation)
        try await record.create(on: req.db)
        return try makePlan(record)
    }

    func plans(portfolioId: UUID, userId: UUID, req: Request) async throws -> [RebalancePlan] {
        _ = try await access(portfolioId, userId: userId, req: req)
        let records = try await RebalancePlanRecord.query(on: req.db)
            .filter(\.$portfolioId == portfolioId)
            .sort(\.$createdAt, .descending)
            .limit(100)
            .all()
        return try records.map(makePlan)
    }

    func transitionPlan(
        portfolioId: UUID,
        planId: UUID,
        userId: UUID,
        status: RebalancePlanStatus,
        note: String?,
        req: Request
    ) async throws -> RebalancePlan {
        _ = try await access(portfolioId, userId: userId, editing: true, req: req)
        guard let record = try await RebalancePlanRecord.query(on: req.db)
            .filter(\.$id == planId)
            .filter(\.$portfolioId == portfolioId)
            .first()
        else { throw Abort(.notFound, reason: "Rebalancing plan not found.") }
        guard record.status == RebalancePlanStatus.draft.rawValue ||
            record.status == RebalancePlanStatus.exported.rawValue
        else { throw Abort(.conflict, reason: "Completed or cancelled plans are immutable.") }
        let now = Date()
        switch status {
        case .completed:
            record.completedAt = now
            record.completionNote = note.flatMap(optionalNormalizedName)
        case .cancelled:
            record.cancelledAt = now
        case .exported:
            record.exportedAt = now
        case .draft:
            throw Abort(.badRequest, reason: "A plan cannot transition back to draft.")
        }
        record.status = status.rawValue
        try await record.save(on: req.db)
        return try makePlan(record)
    }

    func history(portfolioId: UUID, userId: UUID, req: Request) async throws -> RebalancingHistorySummary {
        _ = try await access(portfolioId, userId: userId, req: req)
        let records = try await RebalancePlanRecord.query(on: req.db)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$status == RebalancePlanStatus.completed.rawValue)
            .sort(\.$completedAt, .ascending)
            .all()
        guard !records.isEmpty else {
            return .init(completedCount: 0, averageDriftBeforeBasisPoints: 0, averageDriftAfterBasisPoints: 0)
        }
        let before = records.reduce(0) { $0 + $1.driftBeforeBasisPoints } / records.count
        let after = records.reduce(0) { $0 + $1.driftAfterBasisPoints } / records.count
        let dates = records.compactMap(\.completedAt)
        let averageDays: Double? = if dates.count > 1 {
            zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) / 86400 }.reduce(0, +) / Double(dates.count - 1)
        } else {
            nil
        }
        return .init(
            completedCount: records.count,
            averageDriftBeforeBasisPoints: before,
            averageDriftAfterBasisPoints: after,
            averageDaysBetweenRebalances: averageDays,
            lastCompletedAt: formatISODateTime(dates.last)
        )
    }

    func alerts(userId: UUID, req: Request) async throws -> [RebalancingAlert] {
        try await RebalancingAlertRecord.query(on: req.db)
            .filter(\.$userId == userId)
            .sort(\.$triggeredAt, .descending)
            .limit(100)
            .all()
            .map(makeAlert)
    }

    func acknowledge(alertId: UUID, userId: UUID, req: Request) async throws -> RebalancingAlert {
        guard let record = try await RebalancingAlertRecord.query(on: req.db)
            .filter(\.$id == alertId)
            .filter(\.$userId == userId)
            .first()
        else { throw Abort(.notFound, reason: "Drift alert not found.") }
        guard record.status != RebalancingAlertStatus.resolved.rawValue else {
            return try makeAlert(record)
        }
        record.status = RebalancingAlertStatus.acknowledged.rawValue
        record.acknowledgedAt = Date()
        try await record.save(on: req.db)
        return try makeAlert(record)
    }

    func preferences(portfolioId: UUID, userId: UUID, req: Request) async throws -> RebalancingNotificationPreferences {
        _ = try await access(portfolioId, userId: userId, req: req)
        let record = try await RebalancingNotificationPreferenceRecord.query(on: req.db)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$userId == userId)
            .first()
        return .init(portfolioId: portfolioId.uuidString, pushEnabled: record?.pushEnabled ?? false)
    }

    func updatePreferences(
        portfolioId: UUID,
        userId: UUID,
        payload: UpdateRebalancingNotificationPreferencesRequest,
        req: Request
    ) async throws -> RebalancingNotificationPreferences {
        _ = try await access(portfolioId, userId: userId, req: req)
        if let record = try await RebalancingNotificationPreferenceRecord.query(on: req.db)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$userId == userId)
            .first()
        {
            record.pushEnabled = payload.pushEnabled
            try await record.save(on: req.db)
        } else {
            try await RebalancingNotificationPreferenceRecord(
                portfolioId: portfolioId,
                userId: userId,
                pushEnabled: payload.pushEnabled
            ).create(on: req.db)
        }
        return .init(portfolioId: portfolioId.uuidString, pushEnabled: payload.pushEnabled)
    }

    func dashboard(userId: UUID, req: Request) async throws -> RebalancingDashboardSummary {
        let owned = try await PortfolioList.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$archivedAt == nil)
            .all()
        let memberIds = try await PortfolioMembershipRecord.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$status == PortfolioMembershipStatus.active.rawValue)
            .all()
            .map(\.portfolioId)
        let ids = Array(Set(owned.compactMap(\.id) + memberIds))
        var overviews = [RebalancingOverview]()
        for id in ids {
            guard try await activeModel(portfolioId: id, on: req.db) != nil else { continue }
            if let overview = try? await overview(portfolioId: id, userId: userId, req: req) {
                overviews.append(overview)
            }
        }
        let count = try await RebalancingAlertRecord.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$status != RebalancingAlertStatus.resolved.rawValue)
            .count()
        return .init(
            openAlertCount: count,
            breachedPortfolioCount: overviews.filter { $0.severity == .breached }.count,
            portfolios: overviews
        )
    }

    private func access(
        _ portfolioId: UUID,
        userId: UUID,
        editing: Bool = false,
        req: Request
    ) async throws -> PortfolioAccessContext {
        try await req.portfolioAccessService.require(
            portfolioId: portfolioId,
            userId: userId,
            editing: editing,
            on: req.db
        )
    }

    private func validate(
        _ payload: AllocationModelUpsertRequest,
        portfolioId: UUID,
        baseCurrency: String
    ) throws {
        let model = AllocationModel(
            id: UUID().uuidString,
            portfolioId: portfolioId.uuidString,
            name: payload.name,
            groupingMode: payload.groupingMode,
            isActive: payload.activate,
            revision: payload.expectedRevision ?? 1,
            baseCurrency: baseCurrency,
            defaultTargetThresholdBasisPoints: payload.defaultTargetThresholdBasisPoints,
            totalThresholdBasisPoints: payload.totalThresholdBasisPoints,
            fractionalSharesEnabled: payload.fractionalSharesEnabled,
            quantityIncrement: payload.quantityIncrement,
            minimumTradeAmount: payload.minimumTradeAmount,
            flatFee: payload.flatFee,
            variableFeeBasisPoints: payload.variableFeeBasisPoints,
            buckets: payload.buckets,
            createdAt: ""
        )
        do { try engine.validate(model) } catch { throw mapEngineError(error) }
    }

    private func replaceTargets(
        modelId: UUID,
        buckets: [AllocationTargetBucket],
        on database: any Database
    ) async throws {
        for (bucketIndex, input) in buckets.enumerated() {
            let bucketId = UUID()
            let bucket = AllocationBucketRecord(
                id: bucketId,
                modelId: modelId,
                name: normalizedName(input.name),
                targetBasisPoints: input.targetBasisPoints,
                alertThresholdBasisPoints: input.alertThresholdBasisPoints,
                sectorKey: input.sectorKey.flatMap(optionalNormalizedName),
                sortOrder: bucketIndex
            )
            try await bucket.create(on: database)
            for (leafIndex, inputLeaf) in input.leaves.enumerated() {
                let symbol = inputLeaf.kind == .security ? normalizedSymbol(inputLeaf.symbol) : nil
                let leaf = AllocationLeafRecord(
                    modelId: modelId,
                    bucketId: bucketId,
                    kind: inputLeaf.kind.rawValue,
                    symbol: symbol,
                    name: normalizedName(inputLeaf.name),
                    targetBasisPoints: inputLeaf.targetBasisPoints,
                    alertThresholdBasisPoints: inputLeaf.alertThresholdBasisPoints,
                    sortOrder: leafIndex
                )
                try await leaf.create(on: database)
            }
        }
    }

    private func makeModel(_ record: AllocationModelRecord, on database: any Database) async throws -> AllocationModel {
        let modelId = try record.requireID()
        let buckets = try await AllocationBucketRecord.query(on: database)
            .filter(\.$modelId == modelId)
            .sort(\.$sortOrder, .ascending)
            .all()
        let leaves = try await AllocationLeafRecord.query(on: database)
            .filter(\.$modelId == modelId)
            .sort(\.$sortOrder, .ascending)
            .all()
        let leavesByBucket = Dictionary(grouping: leaves, by: \.bucketId)
        return try AllocationModel(
            id: modelId.uuidString,
            portfolioId: record.portfolioId.uuidString,
            name: record.name,
            groupingMode: AllocationGroupingMode(rawValue: record.groupingMode) ?? .custom,
            isActive: record.isActive,
            revision: record.revision,
            baseCurrency: record.baseCurrency,
            defaultTargetThresholdBasisPoints: record.defaultTargetThresholdBasisPoints,
            totalThresholdBasisPoints: record.totalThresholdBasisPoints,
            fractionalSharesEnabled: record.fractionalSharesEnabled,
            quantityIncrement: record.quantityIncrement,
            minimumTradeAmount: record.minimumTradeAmount,
            flatFee: record.flatFee,
            variableFeeBasisPoints: record.variableFeeBasisPoints,
            buckets: buckets.map { bucket in
                let bucketId = try bucket.requireID()
                return try AllocationTargetBucket(
                    id: bucketId.uuidString,
                    name: bucket.name,
                    targetBasisPoints: bucket.targetBasisPoints,
                    alertThresholdBasisPoints: bucket.alertThresholdBasisPoints,
                    sectorKey: bucket.sectorKey,
                    sortOrder: bucket.sortOrder,
                    leaves: (leavesByBucket[bucketId] ?? []).map { leaf in
                        try AllocationTargetLeaf(
                            id: leaf.requireID().uuidString,
                            kind: AllocationTargetKind(rawValue: leaf.kind) ?? .security,
                            symbol: leaf.symbol,
                            name: leaf.name,
                            targetBasisPoints: leaf.targetBasisPoints,
                            alertThresholdBasisPoints: leaf.alertThresholdBasisPoints,
                            sortOrder: leaf.sortOrder
                        )
                    }
                )
            },
            createdAt: formatISODateTime(record.createdAt) ?? "",
            updatedAt: formatISODateTime(record.updatedAt)
        )
    }

    private func valuation(
        portfolioId: UUID,
        dataOwnerUserId: UUID,
        baseCurrency: String,
        model: AllocationModel?,
        req: Request
    ) async throws -> RebalancingValuationSnapshot {
        let stocks = try await Stock.query(on: req.db)
            .filter(\.$userId == dataOwnerUserId)
            .filter(\.$portfolioListId == portfolioId)
            .all()
        var quantityBySymbol: [String: Double] = [:]
        var basisBySymbol: [String: Double] = [:]
        for stock in stocks {
            let symbol = normalizedSymbol(stock.symbol) ?? ""
            guard !symbol.isEmpty else { continue }
            quantityBySymbol[symbol, default: 0] += stock.shares
            basisBySymbol[symbol, default: 0] += stock.shares * stock.buyPrice
        }
        let targetSymbols = model?.buckets.flatMap(\.leaves).compactMap { leaf in
            leaf.kind == .security ? normalizedSymbol(leaf.symbol) : nil
        } ?? []
        let symbols = Array(Set(quantityBySymbol.keys).union(targetSymbols)).sorted()
        let quotes = await fetchQuotes(symbols: symbols, req: req)
        let cashByCurrency = try await cashBalances(
            portfolioId: portfolioId,
            userId: dataOwnerUserId,
            on: req.db
        )
        var warnings = [RebalancingValuationWarning]()
        var quality = RebalancingPriceQuality.live
        var oldestPriceDate: Date?
        var rates: [String: Double] = [baseCurrency.uppercased(): 1]
        let currencies = Set(quotes.values.compactMap(\.currency).map { $0.uppercased() })
            .union(cashByCurrency.keys)
        for currency in currencies where currency != baseCurrency.uppercased() {
            do {
                let fx = try await req.application.marketDataService.fx(
                    pair: "\(currency)/\(baseCurrency.uppercased())",
                    on: req
                )
                rates[currency] = fx.rate
            } catch {
                rates[currency] = 1
                quality = .incomplete
                warnings.append(.init(code: "missing_fx", message: "Missing \(currency)/\(baseCurrency) exchange rate."))
            }
        }

        let now = Date()
        var holdings = [RebalancingHolding]()
        for symbol in symbols {
            let quantity = quantityBySymbol[symbol, default: 0]
            let averageCost = quantity > 0 ? basisBySymbol[symbol, default: 0] / quantity : 0
            if let quote = quotes[symbol] {
                let date = Date(timeIntervalSince1970: quote.timestamp)
                oldestPriceDate = min(oldestPriceDate ?? date, date)
                if now.timeIntervalSince(date) > 72 * 60 * 60, quality == .live {
                    quality = .stale
                    warnings.append(.init(code: "stale_price", symbol: symbol, message: "The latest price for \(symbol) is stale."))
                }
                let rate = rates[quote.currency.uppercased(), default: 1]
                holdings.append(
                    .init(
                        symbol: symbol,
                        name: symbol,
                        quantity: quantity,
                        price: quote.currentPrice * rate,
                        averageCost: averageCost * rate
                    )
                )
            } else if quantity > 0 {
                quality = .incomplete
                let fallback = averageCost > 0 ? averageCost : 0.01
                warnings.append(.init(code: "missing_price", symbol: symbol, message: "No current price is available for \(symbol)."))
                holdings.append(.init(symbol: symbol, name: symbol, quantity: quantity, price: fallback, averageCost: averageCost))
            } else {
                quality = .incomplete
                warnings.append(.init(code: "missing_target_price", symbol: symbol, message: "No current price is available for target \(symbol)."))
            }
        }
        let cash = cashByCurrency.reduce(0) { total, item in
            total + item.value * rates[item.key, default: 1]
        }
        return .init(
            holdings: holdings,
            cash: cash,
            baseCurrency: baseCurrency,
            priceQuality: quality,
            pricedAt: formatISODateTime(oldestPriceDate),
            warnings: warnings
        )
    }

    private func fetchQuotes(symbols: [String], req: Request) async -> [String: QuoteResponse] {
        guard !symbols.isEmpty else { return [:] }
        var result: [String: QuoteResponse] = [:]
        for start in stride(from: 0, to: symbols.count, by: 10) {
            let chunk = Array(symbols[start ..< min(start + 10, symbols.count)])
            let application = req.application
            let values = await withTaskGroup(of: QuoteResponse?.self) { group in
                for symbol in chunk {
                    group.addTask {
                        let child = Request(application: application, on: application.eventLoopGroup.next())
                        return try? await application.marketDataService.quote(symbol: symbol, on: child)
                    }
                }
                var values = [QuoteResponse]()
                for await value in group {
                    if let value {
                        values.append(value)
                    }
                }
                return values
            }
            for value in values {
                result[value.symbol.uppercased()] = value
            }
        }
        return result
    }

    private func cashBalances(
        portfolioId: UUID,
        userId: UUID,
        on database: any Database
    ) async throws -> [String: Double] {
        let manual = try await PortfolioCashPositionRecord.query(on: database)
            .filter(\.$portfolioId == portfolioId)
            .all()
        var totals = [String: Double]()
        for position in manual {
            totals[position.currency.uppercased(), default: 0] += max(0, position.balance)
        }
        let accounts = try await Account.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$portfolioId == portfolioId)
            .all()
        let accountIds = accounts.compactMap(\.id)
        guard !accountIds.isEmpty else { return totals }
        let balances = try await CashBalance.query(on: database)
            .filter(\.$accountId ~~ accountIds)
            .all()
        var latest: [String: CashBalance] = [:]
        for balance in balances {
            let key = "\(balance.accountId):\(balance.currency.uppercased())"
            if latest[key]?.asOf ?? .distantPast < balance.asOf {
                latest[key] = balance
            }
        }
        for balance in latest.values {
            totals[balance.currency.uppercased(), default: 0] += max(0, balance.balance)
        }
        return totals
    }

    private func makePlan(_ record: RebalancePlanRecord) throws -> RebalancePlan {
        let simulation = try JSONDecoder.stockPlanShared.decode(
            RebalancingSimulation.self,
            from: Data(record.simulationJSON.utf8)
        )
        return try RebalancePlan(
            id: record.requireID().uuidString,
            portfolioId: record.portfolioId.uuidString,
            modelId: record.modelId.uuidString,
            modelRevision: record.modelRevision,
            name: record.name,
            status: RebalancePlanStatus(rawValue: record.status) ?? .draft,
            baseCurrency: record.baseCurrency,
            driftBeforeBasisPoints: record.driftBeforeBasisPoints,
            driftAfterBasisPoints: record.driftAfterBasisPoints,
            totalValue: record.totalValue,
            estimatedFees: record.estimatedFees,
            estimatedRealizedGainLoss: record.estimatedRealizedGainLoss,
            trades: simulation.trades,
            createdAt: formatISODateTime(record.createdAt) ?? "",
            exportedAt: formatISODateTime(record.exportedAt),
            completedAt: formatISODateTime(record.completedAt),
            cancelledAt: formatISODateTime(record.cancelledAt)
        )
    }

    private func makeAlert(_ record: RebalancingAlertRecord) throws -> RebalancingAlert {
        try RebalancingAlert(
            id: record.requireID().uuidString,
            portfolioId: record.portfolioId.uuidString,
            modelId: record.modelId.uuidString,
            scopeId: record.scopeId,
            scopeName: record.scopeName,
            driftBasisPoints: record.driftBasisPoints,
            thresholdBasisPoints: record.thresholdBasisPoints,
            status: RebalancingAlertStatus(rawValue: record.status) ?? .open,
            triggeredAt: formatISODateTime(record.triggeredAt) ?? "",
            acknowledgedAt: formatISODateTime(record.acknowledgedAt),
            resolvedAt: formatISODateTime(record.resolvedAt)
        )
    }

    private func activeModel(portfolioId: UUID, on database: any Database) async throws -> AllocationModelRecord? {
        try await AllocationModelRecord.query(on: database)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$isActive == true)
            .sort(\.$updatedAt, .descending)
            .first()
    }

    private func deactivateModels(portfolioId: UUID, except: UUID?, on database: any Database) async throws {
        let records = try await AllocationModelRecord.query(on: database)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$isActive == true)
            .all()
        for record in records where record.id != except {
            record.isActive = false
            try await record.save(on: database)
        }
    }

    private func resolveAlerts(modelId: UUID, on database: any Database) async throws {
        let records = try await RebalancingAlertRecord.query(on: database)
            .filter(\.$modelId == modelId)
            .filter(\.$status != RebalancingAlertStatus.resolved.rawValue)
            .all()
        for record in records {
            record.status = RebalancingAlertStatus.resolved.rawValue
            record.resolvedAt = Date()
            record.activeScopeKey = nil
            try await record.save(on: database)
        }
    }

    private func encode(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder.backendAPI.encode(value), as: UTF8.self)
    }

    private func mapEngineError(_ error: any Error) -> Abort {
        switch error {
        case RebalancingEngineError.staleModel:
            Abort(.conflict, reason: "Allocation model changed. Reload before simulating.")
        case let RebalancingEngineError.invalidModel(reason):
            Abort(.badRequest, reason: reason)
        case let RebalancingEngineError.invalidHolding(reason):
            Abort(.unprocessableEntity, reason: reason)
        case let RebalancingEngineError.unknownOverride(symbol):
            Abort(.badRequest, reason: "Unknown or duplicate trade override: \(symbol).")
        case let RebalancingEngineError.oversell(symbol):
            Abort(.unprocessableEntity, reason: "A sell override exceeds the available \(symbol) holding.")
        case RebalancingEngineError.invalidCashFlow:
            Abort(.badRequest, reason: "Cash flow must be a finite amount.")
        case RebalancingEngineError.insufficientCash:
            Abort(.unprocessableEntity, reason: "The proposed trades would create a negative cash balance.")
        default:
            Abort(.internalServerError, reason: "Rebalancing calculation failed.")
        }
    }

    private func normalizedName(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    private func optionalNormalizedName(_ raw: String) -> String? {
        let value = normalizedName(raw)
        return value.isEmpty ? nil : value
    }

    private func normalizedSymbol(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return value.isEmpty ? nil : String(value.prefix(24))
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}

extension Application {
    private struct RebalancingServiceKey: StorageKey {
        typealias Value = any RebalancingServicing
    }

    var rebalancingService: any RebalancingServicing {
        get {
            guard let service = storage[RebalancingServiceKey.self] else {
                fatalError("RebalancingServicing not configured")
            }
            return service
        }
        set { storage[RebalancingServiceKey.self] = newValue }
    }
}

extension Request {
    var rebalancingService: any RebalancingServicing {
        application.rebalancingService
    }
}
