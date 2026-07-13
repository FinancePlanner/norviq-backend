import Fluent
import Foundation
import StockPlanShared
import Vapor

struct GermanyFundAnnualInputService: Sendable {
    func save(
        userId: UUID,
        request: TaxFundAnnualInputRequest,
        on database: any Database
    ) async throws -> TaxFundAdvanceLumpSumResponse {
        guard let accountID = UUID(uuidString: request.accountId),
              let instrumentID = UUID(uuidString: request.instrumentId)
        else { throw Abort(.badRequest, reason: "Invalid account or instrument id.") }
        guard request.currency.count == 3 else {
            throw Abort(.unprocessableEntity, reason: "Currency must be a three-letter code.")
        }
        guard !request.holdings.isEmpty, request.holdings.count <= 100 else {
            throw Abort(.unprocessableEntity, reason: "Provide between 1 and 100 annual holding tranches.")
        }
        let holdingIDs = request.holdings.map(\.id)
        guard Set(holdingIDs).count == holdingIDs.count,
              holdingIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw Abort(.unprocessableEntity, reason: "Holding ids must be non-empty and unique.") }

        guard let account = try await Account.find(accountID, on: database), account.userId == userId,
              let instrument = try await Instrument.find(instrumentID, on: database),
              let classification = instrument.fundClassification.flatMap(TaxFundClassification.init(rawValue:)),
              classification != .unknown
        else { throw Abort(.notFound, reason: "Classified fund holding not found.") }
        let ownsTransaction = try await Transaction.query(on: database)
            .filter(\.$accountId == accountID)
            .filter(\.$instrumentId == instrumentID)
            .first() != nil
        let ownedLots = try await Lot.query(on: database)
            .filter(\.$accountId == accountID)
            .filter(\.$instrumentId == instrumentID)
            .sort(\.$openDate, .ascending)
            .all()
        guard ownsTransaction || !ownedLots.isEmpty else {
            throw Abort(.notFound, reason: "Classified fund holding not found.")
        }

        let ownedLotsByID = Dictionary(uniqueKeysWithValues: ownedLots.compactMap { lot in
            lot.id.map { ($0, lot) }
        })
        let calculated = try request.holdings.map { holding in
            let resolvedLot: Lot?
            let resolvedQuantity: Decimal?
            if let rawLotID = holding.lotId, let quantity = holding.quantity {
                guard let lotID = UUID(uuidString: rawLotID),
                      let lot = ownedLotsByID[lotID],
                      quantity > 0,
                      quantity <= Decimal(lot.openQuantity)
                else { throw Abort(.unprocessableEntity, reason: "Invalid annual holding lot or quantity.") }
                resolvedLot = lot
                resolvedQuantity = quantity
            } else if holding.lotId != nil || holding.quantity != nil {
                throw Abort(.unprocessableEntity, reason: "Lot id and quantity must be provided together.")
            } else if request.holdings.count == 1, ownedLots.count == 1 {
                resolvedLot = ownedLots[0]
                resolvedQuantity = Decimal(ownedLots[0].openQuantity)
            } else {
                resolvedLot = nil
                resolvedQuantity = nil
            }
            let result: GermanyAdvanceLumpSumResult
            do {
                result = try GermanyAdvanceLumpSumCalculator.calculate(.init(
                    calculationYear: request.calculationYear,
                    beginningMarketValue: holding.beginningMarketValue,
                    endingMarketValue: holding.endingMarketValue,
                    distributions: holding.distributions,
                    acquisitionMonth: holding.acquisitionMonth,
                    fundClassification: classification
                ))
            } catch {
                throw Abort(.unprocessableEntity, reason: "Invalid annual fund input: \(error).")
            }
            return CalculatedHolding(
                input: holding,
                result: result,
                lot: resolvedLot,
                quantity: resolvedQuantity
            )
        }
        let ruleVersion = TaxRuleRegistry(validatedJurisdictions: [.germany]).pack(for: .germany).ruleVersion
        let currency = request.currency.uppercased()

        try await database.transaction { transaction in
            try await GermanyFundAnnualHolding.query(on: transaction)
                .filter(\.$userId == userId)
                .filter(\.$accountId == accountID)
                .filter(\.$instrumentId == instrumentID)
                .filter(\.$calculationYear == request.calculationYear)
                .delete()
            for calculatedHolding in calculated {
                let stored = GermanyFundAnnualHolding()
                stored.userId = userId
                stored.accountId = accountID
                stored.instrumentId = instrumentID
                stored.calculationYear = request.calculationYear
                stored.clientHoldingId = calculatedHolding.input.id
                if let resolvedLot = calculatedHolding.lot,
                   let resolvedQuantity = calculatedHolding.quantity
                {
                    stored.lotId = resolvedLot.id
                    stored.quantity = NSDecimalNumber(decimal: resolvedQuantity).doubleValue
                    stored.remainingQuantity = stored.quantity
                }
                stored.currency = currency
                stored.beginningMarketValue = NSDecimalNumber(decimal: calculatedHolding.input.beginningMarketValue).doubleValue
                stored.endingMarketValue = NSDecimalNumber(decimal: calculatedHolding.input.endingMarketValue).doubleValue
                stored.distributions = NSDecimalNumber(decimal: calculatedHolding.input.distributions).doubleValue
                stored.acquisitionMonth = calculatedHolding.input.acquisitionMonth
                stored.fundClassification = classification.rawValue
                stored.basisRate = NSDecimalNumber(decimal: calculatedHolding.result.basisRate).doubleValue
                stored.grossAdvanceLumpSum = NSDecimalNumber(decimal: calculatedHolding.result.grossAdvanceLumpSum).doubleValue
                stored.remainingGrossAdvance = stored.grossAdvanceLumpSum
                stored.taxableAdvanceLumpSum = NSDecimalNumber(decimal: calculatedHolding.result.taxableAdvanceLumpSum).doubleValue
                stored.ruleVersion = ruleVersion
                try await stored.create(on: transaction)
            }
        }
        return response(
            accountID: accountID,
            instrumentID: instrumentID,
            calculationYear: request.calculationYear,
            currency: currency,
            classification: classification,
            holdings: calculated,
            updatedAt: Date()
        )
    }

    func get(
        userId: UUID,
        accountId: UUID,
        instrumentId: UUID,
        calculationYear: Int,
        on database: any Database
    ) async throws -> TaxFundAdvanceLumpSumResponse? {
        let rows = try await GermanyFundAnnualHolding.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$accountId == accountId)
            .filter(\.$instrumentId == instrumentId)
            .filter(\.$calculationYear == calculationYear)
            .sort(\.$clientHoldingId, .ascending)
            .all()
        guard let first = rows.first,
              let classification = TaxFundClassification(rawValue: first.fundClassification)
        else { return nil }
        let holdings: [TaxFundAnnualHoldingInput] = rows.map { row in
            let quantity = row.quantity.map { Decimal($0) }
            return TaxFundAnnualHoldingInput(
                id: row.clientHoldingId,
                lotId: row.lotId?.uuidString,
                quantity: quantity,
                beginningMarketValue: Decimal(row.beginningMarketValue),
                endingMarketValue: Decimal(row.endingMarketValue),
                distributions: Decimal(row.distributions),
                acquisitionMonth: row.acquisitionMonth
            )
        }
        return TaxFundAdvanceLumpSumResponse(
            accountId: accountId.uuidString,
            instrumentId: instrumentId.uuidString,
            calculationYear: calculationYear,
            deemedReceiptTaxYear: calculationYear + 1,
            currency: first.currency,
            fundClassification: classification,
            basisRate: Decimal(first.basisRate),
            grossAdvanceLumpSum: rows.reduce(Decimal.zero) { $0 + Decimal($1.grossAdvanceLumpSum) },
            taxableAdvanceLumpSum: rows.reduce(Decimal.zero) { $0 + Decimal($1.taxableAdvanceLumpSum) },
            holdings: holdings,
            updatedAt: isoDate(rows.compactMap(\.updatedAt).max() ?? Date())
        )
    }

    private func response(
        accountID: UUID,
        instrumentID: UUID,
        calculationYear: Int,
        currency: String,
        classification: TaxFundClassification,
        holdings: [CalculatedHolding],
        updatedAt: Date
    ) -> TaxFundAdvanceLumpSumResponse {
        TaxFundAdvanceLumpSumResponse(
            accountId: accountID.uuidString,
            instrumentId: instrumentID.uuidString,
            calculationYear: calculationYear,
            deemedReceiptTaxYear: calculationYear + 1,
            currency: currency,
            fundClassification: classification,
            basisRate: holdings.first?.result.basisRate ?? 0,
            grossAdvanceLumpSum: holdings.reduce(Decimal.zero) { $0 + $1.result.grossAdvanceLumpSum },
            taxableAdvanceLumpSum: holdings.reduce(Decimal.zero) { $0 + $1.result.taxableAdvanceLumpSum },
            holdings: holdings.map { calculatedHolding in
                TaxFundAnnualHoldingInput(
                    id: calculatedHolding.input.id,
                    lotId: calculatedHolding.lot?.id?.uuidString,
                    quantity: calculatedHolding.quantity,
                    beginningMarketValue: calculatedHolding.input.beginningMarketValue,
                    endingMarketValue: calculatedHolding.input.endingMarketValue,
                    distributions: calculatedHolding.input.distributions,
                    acquisitionMonth: calculatedHolding.input.acquisitionMonth
                )
            },
            updatedAt: isoDate(updatedAt)
        )
    }
}

private struct CalculatedHolding {
    let input: TaxFundAnnualHoldingInput
    let result: GermanyAdvanceLumpSumResult
    let lot: Lot?
    let quantity: Decimal?
}
