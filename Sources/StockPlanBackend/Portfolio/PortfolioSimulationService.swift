import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol PortfolioSimulationServicing: Sendable {
    func list(userId: UUID, limit: Int, cursor: String?, on database: any Database) async throws
        -> PortfolioSimulationListResponse
    func detail(simulationId: UUID, userId: UUID, on database: any Database) async throws -> PortfolioSimulation
    func create(userId: UUID, payload: PortfolioSimulationUpsertRequest, req: Request) async throws
        -> PortfolioSimulation
    func update(
        simulationId: UUID,
        userId: UUID,
        payload: PortfolioSimulationUpsertRequest,
        req: Request
    ) async throws -> PortfolioSimulation
    func delete(simulationId: UUID, userId: UUID, on database: any Database) async throws
    func compute(
        simulationId: UUID,
        userId: UUID,
        payload: PortfolioSimulationComputeRequest,
        req: Request
    ) async throws -> PortfolioSimulationResult
    func preview(userId: UUID, payload: PortfolioSimulationUpsertRequest, req: Request) async throws
        -> PortfolioSimulationResult
}

struct DefaultPortfolioSimulationService: PortfolioSimulationServicing {
    private let builder = SimulationAllocationModelBuilder()
    private let pricer = PortfolioSnapshotPricer()
    private let engine = RebalancingEngine()

    private static let maximumLegs = 250

    // MARK: - CRUD

    func list(
        userId: UUID,
        limit: Int,
        cursor: String?,
        on database: any Database
    ) async throws -> PortfolioSimulationListResponse {
        let pageSize = max(1, min(limit, 100))
        var query = PortfolioSimulationRecord.query(on: database)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)

        if let cursor, let anchor = Self.decodeCursor(cursor) {
            query = query.group(.or) { group in
                group.filter(\.$createdAt < anchor.createdAt)
                group.group(.and) { tie in
                    tie.filter(\.$createdAt == anchor.createdAt)
                    tie.filter(\.$id < anchor.id)
                }
            }
        }

        // One extra row tells us whether another page exists without a second query.
        let records = try await query.limit(pageSize + 1).all()
        let page = Array(records.prefix(pageSize))
        let legs = try await legsBySimulation(ids: page.compactMap(\.id), on: database)

        return try PortfolioSimulationListResponse(
            items: page.map { try dto($0, legs: legs[$0.requireID()] ?? []) },
            nextCursor: records.count > pageSize ? Self.encodeCursor(page.last) : nil
        )
    }

    func detail(simulationId: UUID, userId: UUID, on database: any Database) async throws -> PortfolioSimulation {
        let record = try await require(simulationId: simulationId, userId: userId, on: database)
        return try await dto(record, legs: legRecords(for: simulationId, on: database))
    }

    func create(
        userId: UUID,
        payload: PortfolioSimulationUpsertRequest,
        req: Request
    ) async throws -> PortfolioSimulation {
        let legs = try Self.validate(payload)
        if payload.mode == .cloneCurrentPortfolio {
            _ = try await requireSourcePortfolio(payload: payload, userId: userId, req: req)
        }

        let record = PortfolioSimulationRecord(
            userId: userId,
            mode: payload.mode.rawValue,
            sourcePortfolioId: payload.sourcePortfolioId.flatMap(UUID.init(uuidString:)),
            name: Self.cleanName(payload.name),
            baseCurrency: payload.baseCurrency.uppercased(),
            targetCapital: payload.targetCapital,
            fractionalSharesEnabled: payload.fractionalSharesEnabled,
            quantityIncrement: payload.quantityIncrement ?? 0.001,
            minimumTradeAmount: payload.minimumTradeAmount ?? 1,
            flatFee: payload.flatFee ?? 0,
            variableFeeBasisPoints: payload.variableFeeBasisPoints ?? 0
        )
        try await record.save(on: req.db)
        try await replaceLegs(legs, simulationId: record.requireID(), on: req.db)

        return try await dto(record, legs: legRecords(for: record.requireID(), on: req.db))
    }

    func update(
        simulationId: UUID,
        userId: UUID,
        payload: PortfolioSimulationUpsertRequest,
        req: Request
    ) async throws -> PortfolioSimulation {
        let legs = try Self.validate(payload)
        let record = try await require(simulationId: simulationId, userId: userId, on: req.db)

        if let expected = payload.expectedRevision, expected != record.revision {
            throw Abort(.conflict, reason: "This simulation was changed elsewhere. Reload and try again.")
        }
        if payload.mode == .cloneCurrentPortfolio {
            _ = try await requireSourcePortfolio(payload: payload, userId: userId, req: req)
        }

        record.mode = payload.mode.rawValue
        record.sourcePortfolioId = payload.sourcePortfolioId.flatMap(UUID.init(uuidString:))
        record.name = Self.cleanName(payload.name)
        record.baseCurrency = payload.baseCurrency.uppercased()
        record.targetCapital = payload.targetCapital
        record.fractionalSharesEnabled = payload.fractionalSharesEnabled
        record.quantityIncrement = payload.quantityIncrement ?? record.quantityIncrement
        record.minimumTradeAmount = payload.minimumTradeAmount ?? record.minimumTradeAmount
        record.flatFee = payload.flatFee ?? record.flatFee
        record.variableFeeBasisPoints = payload.variableFeeBasisPoints ?? record.variableFeeBasisPoints
        record.revision += 1
        try await record.save(on: req.db)
        try await replaceLegs(legs, simulationId: simulationId, on: req.db)

        return try await dto(record, legs: legRecords(for: simulationId, on: req.db))
    }

    func delete(simulationId: UUID, userId: UUID, on database: any Database) async throws {
        let record = try await require(simulationId: simulationId, userId: userId, on: database)
        try await record.delete(on: database)
    }

    // MARK: - Compute

    func compute(
        simulationId: UUID,
        userId: UUID,
        payload: PortfolioSimulationComputeRequest,
        req: Request
    ) async throws -> PortfolioSimulationResult {
        let record = try await require(simulationId: simulationId, userId: userId, on: req.db)
        var simulation = try await dto(record, legs: legRecords(for: simulationId, on: req.db))
        if let override = payload.targetCapitalOverride {
            simulation = Self.withCapital(simulation, capital: override)
        }
        return try await run(simulation, userId: userId, req: req)
    }

    func preview(
        userId: UUID,
        payload: PortfolioSimulationUpsertRequest,
        req: Request
    ) async throws -> PortfolioSimulationResult {
        let legs = try Self.validate(payload)
        if payload.mode == .cloneCurrentPortfolio {
            _ = try await requireSourcePortfolio(payload: payload, userId: userId, req: req)
        }
        // A preview is never persisted, so it carries a throwaway identity.
        let simulation = PortfolioSimulation(
            id: UUID().uuidString,
            name: Self.cleanName(payload.name),
            mode: payload.mode,
            sourcePortfolioId: payload.sourcePortfolioId,
            baseCurrency: payload.baseCurrency.uppercased(),
            targetCapital: payload.targetCapital,
            fractionalSharesEnabled: payload.fractionalSharesEnabled,
            quantityIncrement: payload.quantityIncrement ?? 0.001,
            minimumTradeAmount: payload.minimumTradeAmount ?? 1,
            flatFee: payload.flatFee ?? 0,
            variableFeeBasisPoints: payload.variableFeeBasisPoints ?? 0,
            revision: 1,
            legs: legs.enumerated().map { offset, leg in
                PortfolioSimulationLeg(
                    symbol: leg.symbol,
                    displayName: leg.displayName,
                    targetBasisPoints: leg.targetBasisPoints,
                    sortOrder: offset
                )
            },
            createdAt: formatISODateTime(Date()) ?? ""
        )
        return try await run(simulation, userId: userId, req: req)
    }

    private func run(
        _ simulation: PortfolioSimulation,
        userId: UUID,
        req: Request
    ) async throws -> PortfolioSimulationResult {
        guard simulation.targetCapital.isFinite, simulation.targetCapital >= 0 else {
            throw Abort(.unprocessableEntity, reason: "Target capital must be a positive amount.")
        }

        let model: AllocationModel
        do {
            model = try builder.makeModel(for: simulation)
        } catch let error as SimulationModelError {
            throw Self.abort(for: error)
        }

        let input = try await pricingInput(for: simulation, userId: userId, req: req)
        let snapshot = try await pricer.snapshot(input, req: req)

        // The engine throws on any target it cannot price. Surfacing that as a 422 that
        // names the symbols beats letting an engine error become a 500.
        let unpriced = pricer.unpricedTargets(in: snapshot)
        if !unpriced.isEmpty {
            throw Abort(
                .unprocessableEntity,
                reason: "No current price is available for \(unpriced.joined(separator: ", "))."
            )
        }

        // From scratch has no positions and no cash, so the whole capital arrives as a
        // cash flow. That also makes the `before` rows read as 100% cash, which is the
        // honest starting picture for a portfolio the user does not own yet.
        let result = try engine.simulate(
            portfolioId: simulation.sourcePortfolioId ?? simulation.id,
            model: model,
            request: builder.makeRequest(for: model, cashFlow: simulation.targetCapital),
            snapshot: snapshot
        )

        let spent = result.trades.reduce(0) { total, trade in
            total + (trade.side == .buy ? trade.notional : -trade.notional)
        }
        let cashNeeded = Self.rounded(spent + result.estimatedFees)
        let leftover = Self.rounded(max(0, simulation.targetCapital - cashNeeded))

        return PortfolioSimulationResult(
            simulationId: simulation.id,
            revision: simulation.revision,
            mode: simulation.mode,
            generatedAt: formatISODateTime(Date()) ?? "",
            simulation: result,
            totalCashNeeded: cashNeeded,
            leftoverCash: leftover,
            cashBasisPoints: simulation.cashBasisPoints,
            diff: Self.diff(before: result.before, after: result.after),
            warnings: snapshot.warnings
        )
    }

    private func pricingInput(
        for simulation: PortfolioSimulation,
        userId: UUID,
        req: Request
    ) async throws -> PortfolioPricingInput {
        let targets = simulation.legs.map { SimulationAllocationModelBuilder.normalize($0.symbol) }

        guard simulation.mode == .cloneCurrentPortfolio,
              let rawId = simulation.sourcePortfolioId,
              let portfolioId = UUID(uuidString: rawId)
        else {
            return PortfolioPricingInput(targetSymbols: targets, baseCurrency: simulation.baseCurrency)
        }

        let context = try await req.application.portfolioAccessService.require(
            portfolioId: portfolioId,
            userId: userId,
            on: req.db
        )
        let stocks = try await Stock.query(on: req.db)
            .filter(\.$userId == context.portfolio.userId)
            .filter(\.$portfolioListId == portfolioId)
            .all()

        var quantityBySymbol: [String: Double] = [:]
        var basisBySymbol: [String: Double] = [:]
        for stock in stocks {
            let symbol = SimulationAllocationModelBuilder.normalize(stock.symbol)
            guard !symbol.isEmpty else { continue }
            quantityBySymbol[symbol, default: 0] += stock.shares
            basisBySymbol[symbol, default: 0] += stock.shares * stock.buyPrice
        }

        return PortfolioPricingInput(
            quantityBySymbol: quantityBySymbol,
            basisBySymbol: basisBySymbol,
            targetSymbols: targets,
            baseCurrency: simulation.baseCurrency
        )
    }

    // MARK: - Persistence helpers

    private func require(
        simulationId: UUID,
        userId: UUID,
        on database: any Database
    ) async throws -> PortfolioSimulationRecord {
        guard let record = try await PortfolioSimulationRecord.query(on: database)
            .filter(\.$id == simulationId)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Simulation not found.")
        }
        return record
    }

    /// Confirms the caller can read the portfolio being cloned. `require` throws
    /// `.notFound` rather than `.forbidden` for non-members, so this cannot be used
    /// to probe which portfolio ids exist.
    @discardableResult
    private func requireSourcePortfolio(
        payload: PortfolioSimulationUpsertRequest,
        userId: UUID,
        req: Request
    ) async throws -> PortfolioAccessContext {
        guard let raw = payload.sourcePortfolioId, let portfolioId = UUID(uuidString: raw) else {
            throw Abort(.unprocessableEntity, reason: "Cloning a portfolio requires a source portfolio.")
        }
        return try await req.application.portfolioAccessService.require(
            portfolioId: portfolioId,
            userId: userId,
            on: req.db
        )
    }

    private func legRecords(for simulationId: UUID, on database: any Database) async throws
        -> [PortfolioSimulationLegRecord]
    {
        try await PortfolioSimulationLegRecord.query(on: database)
            .filter(\.$simulationId == simulationId)
            .sort(\.$sortOrder)
            .all()
    }

    private func legsBySimulation(
        ids: [UUID],
        on database: any Database
    ) async throws -> [UUID: [PortfolioSimulationLegRecord]] {
        guard !ids.isEmpty else { return [:] }
        let records = try await PortfolioSimulationLegRecord.query(on: database)
            .filter(\.$simulationId ~~ ids)
            .sort(\.$sortOrder)
            .all()
        return Dictionary(grouping: records, by: \.simulationId)
    }

    private func replaceLegs(
        _ legs: [PortfolioSimulationLegInput],
        simulationId: UUID,
        on database: any Database
    ) async throws {
        try await PortfolioSimulationLegRecord.query(on: database)
            .filter(\.$simulationId == simulationId)
            .delete()
        for (offset, leg) in legs.enumerated() {
            try await PortfolioSimulationLegRecord(
                simulationId: simulationId,
                symbol: SimulationAllocationModelBuilder.normalize(leg.symbol),
                displayName: leg.displayName,
                targetBasisPoints: leg.targetBasisPoints,
                sortOrder: offset
            ).save(on: database)
        }
    }

    private func dto(
        _ record: PortfolioSimulationRecord,
        legs: [PortfolioSimulationLegRecord]
    ) throws -> PortfolioSimulation {
        try PortfolioSimulation(
            id: record.requireID().uuidString,
            name: record.name,
            mode: PortfolioSimulationMode(rawValue: record.mode) ?? .fromScratch,
            sourcePortfolioId: record.sourcePortfolioId?.uuidString,
            baseCurrency: record.baseCurrency,
            targetCapital: record.targetCapital,
            fractionalSharesEnabled: record.fractionalSharesEnabled,
            quantityIncrement: record.quantityIncrement,
            minimumTradeAmount: record.minimumTradeAmount,
            flatFee: record.flatFee,
            variableFeeBasisPoints: record.variableFeeBasisPoints,
            revision: record.revision,
            legs: legs.map {
                PortfolioSimulationLeg(
                    symbol: $0.symbol,
                    displayName: $0.displayName,
                    targetBasisPoints: $0.targetBasisPoints,
                    sortOrder: $0.sortOrder
                )
            },
            shareEnabled: record.shareEnabled,
            shareShowCapital: record.shareShowCapital,
            shareSlug: record.shareEnabled ? record.shareSlug : nil,
            createdAt: formatISODateTime(record.createdAt) ?? "",
            updatedAt: formatISODateTime(record.updatedAt)
        )
    }

    // MARK: - Validation and shaping

    private static func validate(_ payload: PortfolioSimulationUpsertRequest) throws
        -> [PortfolioSimulationLegInput]
    {
        guard !cleanName(payload.name).isEmpty else {
            throw Abort(.unprocessableEntity, reason: "A simulation name is required.")
        }
        guard payload.targetCapital.isFinite, payload.targetCapital >= 0 else {
            throw Abort(.unprocessableEntity, reason: "Target capital must be a positive amount.")
        }
        guard !payload.legs.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "Add at least one position to simulate.")
        }
        // No product cap on positions, but an unbounded list is a denial-of-service
        // surface on a route that fetches a quote per symbol.
        guard payload.legs.count <= maximumLegs else {
            throw Abort(.unprocessableEntity, reason: "A simulation can hold at most \(maximumLegs) positions.")
        }

        var seen = Set<String>()
        var total = 0
        for leg in payload.legs {
            let symbol = SimulationAllocationModelBuilder.normalize(leg.symbol)
            guard SimulationAllocationModelBuilder.validSymbol(symbol) else {
                throw Abort(.unprocessableEntity, reason: "\"\(leg.symbol)\" is not a valid ticker.")
            }
            guard seen.insert(symbol).inserted else {
                throw Abort(.unprocessableEntity, reason: "\(symbol) appears more than once.")
            }
            guard leg.targetBasisPoints > 0, leg.targetBasisPoints <= 10000 else {
                throw Abort(.unprocessableEntity, reason: "\(symbol) needs a weight between 0.01% and 100%.")
            }
            total += leg.targetBasisPoints
        }
        // Under 100% is allowed and becomes cash. Over 100% is not.
        guard total <= 10000 else {
            throw Abort(.unprocessableEntity, reason: "Weights total more than 100%.")
        }
        return payload.legs
    }

    private static func abort(for error: SimulationModelError) -> Abort {
        switch error {
        case let .weightsExceedTotal(total):
            let percent = Double(total) / 100
            return Abort(.unprocessableEntity, reason: "Weights total \(percent)%, which is more than 100%.")
        case .noLegs:
            return Abort(.unprocessableEntity, reason: "Add at least one position to simulate.")
        case let .duplicateSymbol(symbol):
            return Abort(.unprocessableEntity, reason: "\(symbol) appears more than once.")
        case let .invalidSymbol(symbol):
            return Abort(.unprocessableEntity, reason: "\"\(symbol)\" is not a valid ticker.")
        case let .invalidWeight(symbol):
            return Abort(.unprocessableEntity, reason: "\(symbol) needs a weight between 0.01% and 100%.")
        case .invalidTargetCapital:
            return Abort(.unprocessableEntity, reason: "Target capital must be a positive amount.")
        }
    }

    private static func diff(
        before: [RebalancingAllocationRow],
        after: [RebalancingAllocationRow]
    ) -> [PortfolioSimulationDiffRow] {
        let beforeBySymbol = Dictionary(
            flatten(before).compactMap { row in row.symbol.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )
        let afterBySymbol = Dictionary(
            flatten(after).compactMap { row in row.symbol.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )

        return Set(beforeBySymbol.keys).union(afterBySymbol.keys).sorted().map { symbol in
            PortfolioSimulationDiffRow(
                symbol: symbol,
                currentBasisPoints: beforeBySymbol[symbol]?.currentBasisPoints ?? 0,
                targetBasisPoints: afterBySymbol[symbol]?.targetBasisPoints ?? 0,
                currentValue: beforeBySymbol[symbol]?.currentValue ?? 0,
                targetValue: afterBySymbol[symbol]?.currentValue ?? 0
            )
        }
    }

    private static func flatten(_ rows: [RebalancingAllocationRow]) -> [RebalancingAllocationRow] {
        rows.flatMap { [$0] + flatten($0.children) }
    }

    private static func withCapital(_ simulation: PortfolioSimulation, capital: Double) -> PortfolioSimulation {
        PortfolioSimulation(
            id: simulation.id,
            name: simulation.name,
            mode: simulation.mode,
            sourcePortfolioId: simulation.sourcePortfolioId,
            baseCurrency: simulation.baseCurrency,
            targetCapital: capital,
            fractionalSharesEnabled: simulation.fractionalSharesEnabled,
            quantityIncrement: simulation.quantityIncrement,
            minimumTradeAmount: simulation.minimumTradeAmount,
            flatFee: simulation.flatFee,
            variableFeeBasisPoints: simulation.variableFeeBasisPoints,
            revision: simulation.revision,
            legs: simulation.legs,
            shareEnabled: simulation.shareEnabled,
            shareShowCapital: simulation.shareShowCapital,
            shareSlug: simulation.shareSlug,
            createdAt: simulation.createdAt,
            updatedAt: simulation.updatedAt
        )
    }

    private static func cleanName(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func encodeCursor(_ record: PortfolioSimulationRecord?) -> String? {
        guard let record, let id = record.id, let createdAt = record.createdAt else { return nil }
        return Data("\(createdAt.timeIntervalSince1970):\(id.uuidString)".utf8).base64EncodedString()
    }

    private static func decodeCursor(_ raw: String) -> (createdAt: Date, id: UUID)? {
        guard let data = Data(base64Encoded: raw),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let seconds = Double(parts[0]),
              let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        return (Date(timeIntervalSince1970: seconds), id)
    }
}

extension Application {
    private struct PortfolioSimulationServiceKey: StorageKey {
        typealias Value = any PortfolioSimulationServicing
    }

    var portfolioSimulationService: any PortfolioSimulationServicing {
        get {
            guard let service = storage[PortfolioSimulationServiceKey.self] else {
                fatalError("PortfolioSimulationServicing not configured")
            }
            return service
        }
        set { storage[PortfolioSimulationServiceKey.self] = newValue }
    }
}

extension Request {
    var portfolioSimulationService: any PortfolioSimulationServicing {
        application.portfolioSimulationService
    }
}
