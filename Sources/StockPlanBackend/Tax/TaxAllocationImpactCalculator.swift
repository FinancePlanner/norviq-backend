import Fluent
import Foundation
import StockPlanShared

struct TaxAllocationImpactCalculator: Sendable {
    func impacts(
        userId: UUID,
        opportunities: [TaxOpportunityResponse],
        replacements: [String: TaxReplacementCandidate],
        on database: any Database
    ) async throws -> [TaxAllocationImpact] {
        let accounts = try await Account.query(on: database)
            .filter(\.$userId == userId)
            .all()
        let accountIDs = accounts.compactMap(\.id)
        guard !accountIDs.isEmpty else { return [] }
        let accountByID = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.id.map { ($0, account) }
        })
        let positions = try await Position.query(on: database)
            .filter(\.$accountId ~~ accountIDs)
            .all()
        let instrumentIDs = Set(positions.map(\.instrumentId)).union(
            replacements.values.compactMap { UUID(uuidString: $0.instrumentId) }
        )
        let instruments = instrumentIDs.isEmpty ? [] : try await Instrument.query(on: database)
            .filter(\.$id ~~ Array(instrumentIDs))
            .all()
        let symbolByInstrumentID = Dictionary(uniqueKeysWithValues: instruments.compactMap { instrument in
            instrument.id.map { ($0, instrument.symbol) }
        })
        let opportunitiesByPortfolio = Dictionary(grouping: opportunities) { opportunity in
            opportunity.portfolioId ?? ""
        }

        return opportunitiesByPortfolio.keys.sorted().compactMap { rawPortfolioID in
            guard !rawPortfolioID.isEmpty,
                  let portfolioID = UUID(uuidString: rawPortfolioID),
                  let selected = opportunitiesByPortfolio[rawPortfolioID],
                  let currency = selected.first?.marketValue.currency
            else { return nil }
            let portfolioAccountIDs = Set(accountByID.values.compactMap { account in
                account.portfolioId == portfolioID ? account.id : nil
            })
            var before = [UUID: Decimal]()
            for position in positions
                where portfolioAccountIDs.contains(position.accountId) && position.currency == currency
            {
                let value = position.marketValue
                    ?? position.quantity * (position.lastPrice ?? position.averageCost)
                before[position.instrumentId, default: 0] += Decimal(max(0, value))
            }
            let total = before.values.reduce(Decimal.zero, +)
            guard total > 0 else { return nil }
            var after = before
            var affectedInstrumentIDs = Set<UUID>()
            for opportunity in selected {
                guard let sourceID = UUID(uuidString: opportunity.instrumentId) else { continue }
                let availableSourceValue = after[sourceID, default: 0]
                let notional = min(max(0, opportunity.marketValue.amount), availableSourceValue)
                guard notional > 0 else { continue }
                after[sourceID] = availableSourceValue - notional
                affectedInstrumentIDs.insert(sourceID)
                if let replacement = replacements[opportunity.id],
                   let replacementID = UUID(uuidString: replacement.instrumentId)
                {
                    after[replacementID, default: 0] += notional
                    affectedInstrumentIDs.insert(replacementID)
                }
            }
            let changes = affectedInstrumentIDs.compactMap { instrumentID -> TaxAllocationChange? in
                guard let symbol = symbolByInstrumentID[instrumentID] else { return nil }
                return TaxAllocationChange(
                    instrumentId: instrumentID.uuidString,
                    symbol: symbol,
                    beforeWeight: before[instrumentID, default: 0] / total,
                    afterWeight: after[instrumentID, default: 0] / total
                )
            }.sorted { ($0.symbol, $0.instrumentId) < ($1.symbol, $1.instrumentId) }
            guard !changes.isEmpty else { return nil }
            let maximumChange = changes.map { abs($0.afterWeight - $0.beforeWeight) }.max() ?? 0
            return TaxAllocationImpact(
                portfolioId: rawPortfolioID,
                portfolioValue: TaxMoney(amount: total, currency: currency),
                maximumWeightChange: maximumChange,
                changes: changes
            )
        }
    }
}
