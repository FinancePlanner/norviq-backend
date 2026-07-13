import Fluent
import Foundation
import StockPlanShared
import Vapor

struct TaxLotCandidate: Sendable, Equatable {
    let id: UUID
    let openDate: Date
    let remainingQuantity: Double
    let unitBasis: Double
}

struct TaxLotMatch: Sendable, Equatable {
    let lotId: UUID
    let quantity: Double
    let proceeds: Double
    let costBasis: Double
    let realizedPnL: Double
}

enum TaxLotAccountingError: Error, AbortError {
    case invalidQuantity
    case insufficientQuantity(available: Double, requested: Double)
    case specificIdentificationRequired
    case unknownSpecificLot(UUID)

    var status: HTTPResponseStatus {
        .unprocessableEntity
    }

    var reason: String {
        switch self {
        case .invalidQuantity:
            "Disposal quantity and price must be positive."
        case let .insufficientQuantity(available, requested):
            "Open tax lots contain \(available) units, but \(requested) units were requested."
        case .specificIdentificationRequired:
            "Specific ID accounting requires the broker-confirmed lot identifiers."
        case let .unknownSpecificLot(id):
            "Specific tax lot \(id) is not open or does not belong to this account and instrument."
        }
    }
}

struct TaxLotMatcher: Sendable {
    func match(
        candidates: [TaxLotCandidate],
        quantity: Double,
        unitPrice: Double,
        fees: Double,
        method: TaxLotSelectionMethod,
        specificLotIDs: [UUID] = []
    ) throws -> [TaxLotMatch] {
        guard quantity > 0, unitPrice >= 0, fees >= 0 else { throw TaxLotAccountingError.invalidQuantity }
        let ordered: [TaxLotCandidate]
        switch method {
        case .fifo, .jurisdictionDefault:
            ordered = candidates.sorted { ($0.openDate, $0.id.uuidString) < ($1.openDate, $1.id.uuidString) }
        case .lifo:
            ordered = candidates.sorted { ($0.openDate, $0.id.uuidString) > ($1.openDate, $1.id.uuidString) }
        case .specificID:
            guard !specificLotIDs.isEmpty else { throw TaxLotAccountingError.specificIdentificationRequired }
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            ordered = try specificLotIDs.map { id in
                guard let lot = byID[id] else { throw TaxLotAccountingError.unknownSpecificLot(id) }
                return lot
            }
        }

        let available = ordered.reduce(0) { $0 + max(0, $1.remainingQuantity) }
        guard available + 0.000_000_1 >= quantity else {
            throw TaxLotAccountingError.insufficientQuantity(available: available, requested: quantity)
        }

        var remaining = quantity
        var matches = [TaxLotMatch]()
        for lot in ordered where remaining > 0 {
            let consumed = min(remaining, max(0, lot.remainingQuantity))
            guard consumed > 0 else { continue }
            let allocatedFees = fees * (consumed / quantity)
            let proceeds = consumed * unitPrice - allocatedFees
            let basis = consumed * lot.unitBasis
            matches.append(.init(
                lotId: lot.id,
                quantity: consumed,
                proceeds: proceeds,
                costBasis: basis,
                realizedPnL: proceeds - basis
            ))
            remaining -= consumed
        }
        return matches
    }
}

struct TaxLotAccountingService: Sendable {
    private let matcher = TaxLotMatcher()
    private let washSaleMatcher = TaxWashSaleMatcher()
    private let spainLossDeferralMatcher = SpainLossDeferralMatcher()

    func recordAcquisition(transaction: Transaction, on database: any Database) async throws -> Lot {
        guard let transactionID = transaction.id,
              let quantity = transaction.quantity.map(abs), quantity > 0,
              let price = transaction.price, price >= 0
        else { throw TaxLotAccountingError.invalidQuantity }

        if let existing = try await Lot.query(on: database)
            .filter(\.$openTransactionId == transactionID)
            .first()
        {
            return existing
        }

        let unitBasis = TaxAcquisitionBasisCalculator().unitBasis(
            quantity: quantity,
            price: price,
            fees: transaction.fees ?? 0
        )
        let lot = Lot(
            accountId: transaction.accountId,
            instrumentId: transaction.instrumentId,
            openTransactionId: transactionID,
            openDate: transaction.tradeDate,
            openQuantity: quantity,
            remainingQuantity: quantity,
            openPrice: unitBasis,
            currency: transaction.currency,
            status: "open"
        )
        try await lot.create(on: database)
        return lot
    }

    func recordDisposal(
        transaction: Transaction,
        method: TaxLotSelectionMethod,
        specificLotIDs: [UUID] = [],
        on database: any Database
    ) async throws -> [LotDisposal] {
        guard let transactionID = transaction.id,
              let quantity = transaction.quantity.map(abs),
              let price = transaction.price
        else { throw TaxLotAccountingError.invalidQuantity }

        return try await database.transaction { db in
            let existing = try await LotDisposal.query(on: db)
                .filter(\.$transactionId == transactionID)
                .all()
            if !existing.isEmpty {
                return existing
            }

            let lots = try await Lot.query(on: db)
                .filter(\.$accountId == transaction.accountId)
                .filter(\.$instrumentId == transaction.instrumentId)
                .filter(\.$status == "open")
                .all()
            let lotIDs = lots.compactMap(\.id)
            let adjustments = lotIDs.isEmpty ? [] : try await LotAdjustment.query(on: db)
                .filter(\.$lotId ~~ lotIDs)
                .all()
            let adjustmentByLot = Dictionary(grouping: adjustments, by: \.lotId)
                .mapValues { values in values.reduce(0) { $0 + $1.amount } }
            let candidates = lots.compactMap { lot -> TaxLotCandidate? in
                guard let id = lot.id, lot.remainingQuantity > 0 else { return nil }
                let adjustment = adjustmentByLot[id] ?? 0
                let adjustedUnitBasis = lot.openPrice + adjustment / max(lot.remainingQuantity, 0.000_000_1)
                return .init(id: id, openDate: lot.openDate, remainingQuantity: lot.remainingQuantity, unitBasis: adjustedUnitBasis)
            }
            let matches = try matcher.match(
                candidates: candidates,
                quantity: quantity,
                unitPrice: price,
                fees: transaction.fees ?? 0,
                method: method,
                specificLotIDs: specificLotIDs
            )
            let lotByID = Dictionary(uniqueKeysWithValues: lots.compactMap { lot in lot.id.map { ($0, lot) } })
            var records = [LotDisposal]()
            for match in matches {
                guard let lot = lotByID[match.lotId] else { continue }
                let record = LotDisposal()
                record.lotId = match.lotId
                record.transactionId = transactionID
                record.quantity = match.quantity
                record.proceeds = match.proceeds
                record.costBasis = match.costBasis
                record.realizedPnl = match.realizedPnL
                record.holdingPeriod = holdingPeriod(open: lot.openDate, close: transaction.tradeDate)
                try await record.create(on: db)
                lot.remainingQuantity = max(0, lot.remainingQuantity - match.quantity)
                lot.realizedPnl = (lot.realizedPnl ?? 0) + match.realizedPnL
                if lot.remainingQuantity <= 0.000_000_1 {
                    lot.remainingQuantity = 0
                    lot.status = "closed"
                    lot.closeDate = transaction.tradeDate
                    lot.closeTransactionId = transactionID
                }
                try await lot.save(on: db)
                records.append(record)
            }
            return records
        }
    }

    func recordUSWashSales(
        disposals: [LotDisposal],
        saleTransaction: Transaction,
        userId: UUID,
        ruleVersion: String,
        on database: any Database
    ) async throws -> [WashSaleMatch] {
        guard !disposals.isEmpty else { return [] }
        return try await database.transaction { db in
            let accounts = try await Account.query(on: db).filter(\.$userId == userId).all()
            let accountByID = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
                account.id.map { ($0, account) }
            })
            let accountIDs = Array(accountByID.keys)
            guard !accountIDs.isEmpty,
                  let soldInstrument = try await Instrument.find(saleTransaction.instrumentId, on: db)
            else { return [] }
            let instruments = try await Instrument.query(on: db).all()
            let matchingInstrumentIDs = instruments.compactMap { instrument -> UUID? in
                guard let id = instrument.id else { return nil }
                if id == soldInstrument.id {
                    return id
                }
                guard let soldGroup = soldInstrument.taxIdentityGroup, !soldGroup.isEmpty else { return nil }
                return instrument.taxIdentityGroup == soldGroup ? id : nil
            }
            let calendar = Calendar(identifier: .gregorian)
            guard let start = calendar.date(byAdding: .day, value: -30, to: saleTransaction.tradeDate),
                  let end = calendar.date(byAdding: .day, value: 30, to: saleTransaction.tradeDate)
            else { return [] }
            let replacementLots = try await Lot.query(on: db)
                .filter(\.$accountId ~~ accountIDs)
                .filter(\.$instrumentId ~~ matchingInstrumentIDs)
                .filter(\.$openDate >= start)
                .filter(\.$openDate <= end)
                .all()
            var availableByLot = Dictionary(uniqueKeysWithValues: replacementLots.compactMap { lot in
                lot.id.map { ($0, max(0, lot.openQuantity)) }
            })
            var persisted = [WashSaleMatch]()
            for disposal in disposals where disposal.realizedPnl < 0 {
                guard let disposalID = disposal.id else { continue }
                let replacements = replacementLots.compactMap { lot -> TaxWashSaleReplacement? in
                    guard let lotID = lot.id, let account = accountByID[lot.accountId] else { return nil }
                    let wrapper = TaxAccountWrapper(rawValue: account.taxWrapper ?? "") ?? .unknown
                    let isTaxAdvantaged = wrapper == .traditionalIRA || wrapper == .rothIRA
                    return .init(
                        lotId: lotID,
                        acquisitionDate: lot.openDate,
                        availableQuantity: availableByLot[lotID] ?? 0,
                        isTaxAdvantaged: isTaxAdvantaged
                    )
                }
                let allocations = washSaleMatcher.match(
                    saleDate: saleTransaction.tradeDate,
                    soldQuantity: disposal.quantity,
                    realizedPnL: disposal.realizedPnl,
                    replacements: replacements,
                    calendar: calendar
                )
                for allocation in allocations {
                    let existing = try await WashSaleMatch.query(on: db)
                        .filter(\.$disposalId == disposalID)
                        .filter(\.$replacementLotId == allocation.replacementLotId)
                        .first()
                    if let existing {
                        persisted.append(existing)
                        continue
                    }
                    let match = WashSaleMatch()
                    match.disposalId = disposalID
                    match.replacementLotId = allocation.replacementLotId
                    match.matchedQuantity = allocation.matchedQuantity
                    match.disallowedLoss = allocation.disallowedLoss
                    match.currency = saleTransaction.currency
                    match.isPermanent = allocation.isPermanent
                    match.ruleVersion = ruleVersion
                    try await match.create(on: db)
                    if !allocation.isPermanent {
                        let adjustment = LotAdjustment()
                        adjustment.lotId = allocation.replacementLotId
                        adjustment.sourceTransactionId = saleTransaction.id
                        adjustment.kind = "wash_sale_deferred_loss"
                        adjustment.amount = allocation.disallowedLoss
                        adjustment.quantity = allocation.matchedQuantity
                        adjustment.currency = saleTransaction.currency
                        adjustment.effectiveDate = saleTransaction.tradeDate
                        try await adjustment.create(on: db)
                    }
                    availableByLot[allocation.replacementLotId, default: 0] -= allocation.matchedQuantity
                    persisted.append(match)
                }
            }
            return persisted
        }
    }

    func recordSpainLossDeferrals(
        disposals: [LotDisposal],
        saleTransaction: Transaction,
        userId: UUID,
        ruleVersion: String,
        on database: any Database
    ) async throws -> [WashSaleMatch] {
        guard !disposals.isEmpty else { return [] }
        return try await database.transaction { db in
            let accountIDs = try await Account.query(on: db)
                .filter(\.$userId == userId)
                .all()
                .compactMap(\.id)
            guard !accountIDs.isEmpty,
                  let soldInstrument = try await Instrument.find(saleTransaction.instrumentId, on: db)
            else { return [] }
            guard soldInstrument.regulatedMarketSource != nil,
                  soldInstrument.regulatedMarketReviewedAt != nil
            else { return [] }
            let windowMonths: Int
            switch soldInstrument.regulatedMarketStatus {
            case "regulated": windowMonths = 2
            case "unlisted": windowMonths = 12
            default: return []
            }

            let matchingInstrumentIDs = try await Instrument.query(on: db).all().compactMap { instrument -> UUID? in
                guard let id = instrument.id else { return nil }
                if id == soldInstrument.id {
                    return id
                }
                guard let group = soldInstrument.taxIdentityGroup, !group.isEmpty else { return nil }
                return instrument.taxIdentityGroup == group ? id : nil
            }
            let calendar = Calendar(identifier: .gregorian)
            guard let start = calendar.date(byAdding: .month, value: -windowMonths, to: saleTransaction.tradeDate),
                  let end = calendar.date(byAdding: .month, value: windowMonths, to: saleTransaction.tradeDate)
            else { return [] }
            let soldLotIDs = Set(disposals.map(\.lotId))
            let replacementLots = try await Lot.query(on: db)
                .filter(\.$accountId ~~ accountIDs)
                .filter(\.$instrumentId ~~ matchingInstrumentIDs)
                .filter(\.$openDate >= start)
                .filter(\.$openDate <= end)
                .all()
                .filter { lot in lot.id.map { !soldLotIDs.contains($0) } ?? false }

            var availableByLot = Dictionary(uniqueKeysWithValues: replacementLots.compactMap { lot in
                lot.id.map { ($0, max(0, lot.remainingQuantity)) }
            })
            var persisted = [WashSaleMatch]()
            for disposal in disposals where disposal.realizedPnl < 0 {
                guard let disposalID = disposal.id else { continue }
                let replacements = replacementLots.compactMap { lot -> SpainLossDeferralReplacement? in
                    guard let lotID = lot.id else { return nil }
                    return .init(
                        lotId: lotID,
                        acquisitionDate: lot.openDate,
                        remainingQuantity: availableByLot[lotID] ?? 0
                    )
                }
                let allocations = spainLossDeferralMatcher.match(
                    saleDate: saleTransaction.tradeDate,
                    soldQuantity: disposal.quantity,
                    realizedPnL: disposal.realizedPnl,
                    replacements: replacements,
                    windowMonths: windowMonths,
                    calendar: calendar
                )
                for allocation in allocations {
                    if let existing = try await WashSaleMatch.query(on: db)
                        .filter(\.$disposalId == disposalID)
                        .filter(\.$replacementLotId == allocation.replacementLotId)
                        .first()
                    {
                        persisted.append(existing)
                        continue
                    }
                    let match = WashSaleMatch()
                    match.disposalId = disposalID
                    match.replacementLotId = allocation.replacementLotId
                    match.matchedQuantity = allocation.matchedQuantity
                    match.disallowedLoss = allocation.deferredLoss
                    match.currency = saleTransaction.currency
                    match.isPermanent = false
                    match.ruleVersion = ruleVersion
                    try await match.create(on: db)

                    let adjustment = LotAdjustment()
                    adjustment.lotId = allocation.replacementLotId
                    adjustment.sourceTransactionId = saleTransaction.id
                    adjustment.kind = "spain_homogeneous_security_deferred_loss"
                    adjustment.amount = allocation.deferredLoss
                    adjustment.quantity = allocation.matchedQuantity
                    adjustment.currency = saleTransaction.currency
                    adjustment.effectiveDate = saleTransaction.tradeDate
                    try await adjustment.create(on: db)
                    availableByLot[allocation.replacementLotId, default: 0] -= allocation.matchedQuantity
                    persisted.append(match)
                }
            }
            return persisted
        }
    }

    private func holdingPeriod(open: Date, close: Date) -> String {
        close.timeIntervalSince(open) > 365 * 86400 ? "long_term" : "short_term"
    }
}

struct TaxAcquisitionBasisCalculator: Sendable {
    func unitBasis(quantity: Double, price: Double, fees: Double) -> Double {
        price + abs(fees) / quantity
    }
}

struct TaxWashSaleReplacement: Sendable, Equatable {
    let lotId: UUID
    let acquisitionDate: Date
    let availableQuantity: Double
    let isTaxAdvantaged: Bool
}

struct TaxWashSaleAllocation: Sendable, Equatable {
    let replacementLotId: UUID
    let matchedQuantity: Double
    let disallowedLoss: Double
    let isPermanent: Bool
}

struct TaxWashSaleMatcher: Sendable {
    func match(
        saleDate: Date,
        soldQuantity: Double,
        realizedPnL: Double,
        replacements: [TaxWashSaleReplacement],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [TaxWashSaleAllocation] {
        guard soldQuantity > 0, realizedPnL < 0,
              let windowStart = calendar.date(byAdding: .day, value: -30, to: saleDate),
              let windowEnd = calendar.date(byAdding: .day, value: 30, to: saleDate)
        else { return [] }
        let lossPerUnit = -realizedPnL / soldQuantity
        var remaining = soldQuantity
        var allocations = [TaxWashSaleAllocation]()
        for replacement in replacements
            .filter({ $0.availableQuantity > 0 && $0.acquisitionDate >= windowStart && $0.acquisitionDate <= windowEnd })
            .sorted(by: { ($0.acquisitionDate, $0.lotId.uuidString) < ($1.acquisitionDate, $1.lotId.uuidString) })
            where remaining > 0
        {
            let quantity = min(remaining, replacement.availableQuantity)
            allocations.append(.init(
                replacementLotId: replacement.lotId,
                matchedQuantity: quantity,
                disallowedLoss: quantity * lossPerUnit,
                isPermanent: replacement.isTaxAdvantaged
            ))
            remaining -= quantity
        }
        return allocations
    }
}
