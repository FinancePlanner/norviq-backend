import Fluent
import Foundation
import StockPlanShared

struct TaxRebalancingDraftBridge: Sendable {
    func createDrafts(
        userId: UUID,
        actionPlanID: UUID,
        kind: TaxActionPlanKind,
        legs: [TaxActionLeg],
        on database: any Database
    ) async throws -> [UUID] {
        let executable = legs.filter { $0.side != .futureContribution }
        let grouped = Dictionary(grouping: executable) { $0.portfolioId }
        var planIDs = [UUID]()
        for (rawPortfolioID, portfolioLegs) in grouped {
            guard let rawPortfolioID,
                  let portfolioID = UUID(uuidString: rawPortfolioID),
                  let model = try await AllocationModelRecord.query(on: database)
                  .filter(\.$portfolioId == portfolioID)
                  .filter(\.$createdByUserId == userId)
                  .filter(\.$isActive == true)
                  .first(),
                  let modelID = model.id
            else { continue }

            let accountIDs = portfolioLegs.compactMap { UUID(uuidString: $0.accountId) }
            let positions = accountIDs.isEmpty ? [] : try await Position.query(on: database)
                .filter(\.$accountId ~~ accountIDs)
                .all()
            let totalValue = positions.reduce(0.0) { partial, position in
                partial + max(0, position.marketValue ?? position.quantity * (position.lastPrice ?? position.averageCost))
            }
            let firstSellInstrumentID = portfolioLegs.first(where: { $0.side == .sell })?.instrumentId
            let trades = portfolioLegs.map { leg in
                let notional = NSDecimalNumber(decimal: leg.notional.amount).doubleValue
                let quantity = leg.quantity.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
                let price = quantity > 0 ? notional / quantity : 0
                return RebalanceTrade(
                    symbol: leg.symbol,
                    side: leg.side == .sell ? .sell : .buy,
                    quantity: quantity,
                    price: price,
                    notional: notional,
                    estimatedFee: notional * 0.001,
                    currency: leg.notional.currency,
                    accountId: leg.accountId,
                    instrumentId: leg.instrumentId,
                    selectedLotIds: leg.lotIds,
                    sourceOpportunityId: leg.lotIds.first,
                    replacementForInstrumentId: leg.side == .buy ? firstSellInstrumentID : nil
                )
            }
            var warnings = [RebalancingValuationWarning(
                code: "tax_strategy_draft",
                message: "This draft preserves the accepted tax-strategy legs. Verify current quotes, allocation, and tax treatment before execution."
            )]
            for leg in portfolioLegs where leg.quantity == nil {
                warnings.append(RebalancingValuationWarning(
                    code: "quote_required",
                    symbol: leg.symbol,
                    message: "A reliable current quote is required to calculate quantity; the accepted notional is preserved."
                ))
            }
            let fees = trades.reduce(0.0) { $0 + $1.estimatedFee }
            let simulation = RebalancingSimulation(
                portfolioId: portfolioID.uuidString,
                modelId: modelID.uuidString,
                modelRevision: model.revision,
                baseCurrency: model.baseCurrency,
                totalValueBefore: totalValue,
                totalValueAfter: totalValue - fees,
                driftBeforeBasisPoints: 0,
                driftAfterBasisPoints: 0,
                estimatedFees: fees,
                estimatedRealizedGainLoss: 0,
                trades: trades,
                before: [],
                after: [],
                warnings: warnings,
                pricedAt: nil
            )
            let record = RebalancePlanRecord()
            let planID = UUID()
            record.id = planID
            record.portfolioId = portfolioID
            record.modelId = modelID
            record.createdByUserId = userId
            record.modelRevision = model.revision
            record.name = kind == .harvest ? "Tax-loss harvesting draft" : "Asset-location draft"
            record.status = "draft"
            record.baseCurrency = model.baseCurrency
            record.driftBeforeBasisPoints = 0
            record.driftAfterBasisPoints = 0
            record.totalValue = totalValue
            record.estimatedFees = fees
            record.estimatedRealizedGainLoss = 0
            record.simulationJSON = try Self.encode(simulation)
            try await record.create(on: database)

            let link = TaxActionRebalancingPlanLink()
            link.actionPlanId = actionPlanID
            link.rebalancingPlanId = planID
            try await link.create(on: database)
            planIDs.append(planID)
        }
        return planIDs
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }
}
