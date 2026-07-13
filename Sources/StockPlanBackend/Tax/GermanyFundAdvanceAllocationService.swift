import Fluent
import Foundation

struct GermanyFundAdvanceAllocationService: Sendable {
    func reconcile(
        disposalIDs requestedDisposalIDs: Set<UUID>,
        on database: any Database
    ) async throws -> [UUID: Decimal] {
        guard !requestedDisposalIDs.isEmpty else { return [:] }
        let requestedDisposals = try await LotDisposal.query(on: database)
            .filter(\.$id ~~ Array(requestedDisposalIDs))
            .all()
        let lotIDs = Array(Set(requestedDisposals.map(\.lotId)))
        guard !lotIDs.isEmpty else { return [:] }

        return try await database.transaction { transaction in
            let annualHoldings = try await GermanyFundAnnualHolding.query(on: transaction)
                .filter(\.$lotId ~~ lotIDs)
                .sort(\.$calculationYear, .ascending)
                .all()
            let holdingIDs = annualHoldings.compactMap(\.id)
            guard !holdingIDs.isEmpty else { return [:] }

            let allDisposals = try await LotDisposal.query(on: transaction)
                .filter(\.$lotId ~~ lotIDs)
                .all()
            let transactionIDs = Array(Set(allDisposals.map(\.transactionId)))
            let transactions = try await Transaction.query(on: transaction)
                .filter(\.$id ~~ transactionIDs)
                .all()
            let transactionByID = Dictionary(uniqueKeysWithValues: transactions.compactMap { item in
                item.id.map { ($0, item) }
            })
            let disposalsByLot = Dictionary(grouping: allDisposals, by: \.lotId).mapValues { disposals in
                disposals.sorted {
                    let lhs = transactionByID[$0.transactionId]?.tradeDate ?? .distantFuture
                    let rhs = transactionByID[$1.transactionId]?.tradeDate ?? .distantFuture
                    return (lhs, $0.id?.uuidString ?? "") < (rhs, $1.id?.uuidString ?? "")
                }
            }
            let existing = try await GermanyFundAdvanceAllocation.query(on: transaction)
                .filter(\.$annualHoldingId ~~ holdingIDs)
                .all()
            let existingByKey = Dictionary(uniqueKeysWithValues: existing.map {
                ("\($0.annualHoldingId.uuidString):\($0.disposalId.uuidString)", $0)
            })
            var retainedIDs = Set<UUID>()
            var allocatedByDisposal = [UUID: Decimal]()

            for holding in annualHoldings {
                guard let holdingID = holding.id,
                      let lotID = holding.lotId,
                      let originalQuantity = holding.quantity,
                      originalQuantity > 0
                else { continue }
                var remainingQuantity = originalQuantity
                var remainingGross = holding.grossAdvanceLumpSum
                let perUnitAdvance = holding.grossAdvanceLumpSum / originalQuantity
                var calendar = Calendar(identifier: .iso8601)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let deemedYear = holding.calculationYear + 1

                for disposal in disposalsByLot[lotID] ?? [] {
                    guard let disposalID = disposal.id,
                          let tradeDate = transactionByID[disposal.transactionId]?.tradeDate,
                          calendar.component(.year, from: tradeDate) >= deemedYear,
                          remainingQuantity > 0
                    else { continue }
                    let quantity = min(disposal.quantity, remainingQuantity)
                    let amount = min(remainingGross, quantity * perUnitAdvance)
                    guard quantity > 0, amount > 0 else { continue }
                    remainingQuantity -= quantity
                    remainingGross -= amount

                    let key = "\(holdingID.uuidString):\(disposalID.uuidString)"
                    let allocation = existingByKey[key]
                        ?? GermanyFundAdvanceAllocation(
                            annualHoldingId: holdingID,
                            disposalId: disposalID,
                            quantity: quantity,
                            grossAdvanceAmount: amount
                        )
                    allocation.quantity = quantity
                    allocation.grossAdvanceAmount = amount
                    try await allocation.save(on: transaction)
                    if let allocationID = allocation.id {
                        retainedIDs.insert(allocationID)
                    }
                    if requestedDisposalIDs.contains(disposalID) {
                        allocatedByDisposal[disposalID, default: 0] += Decimal(amount)
                    }
                }
                holding.remainingQuantity = remainingQuantity
                holding.remainingGrossAdvance = max(0, remainingGross)
                try await holding.save(on: transaction)
            }

            for allocation in existing {
                guard let allocationID = allocation.id, !retainedIDs.contains(allocationID) else { continue }
                try await allocation.delete(on: transaction)
            }
            return allocatedByDisposal
        }
    }
}
