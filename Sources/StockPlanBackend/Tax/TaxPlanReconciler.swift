import Fluent
import Foundation
import StockPlanShared

struct TaxPlanReconciler: Sendable {
    struct Match: Sendable {
        let legID: UUID
        let planID: UUID
        let lotIDs: [UUID]
    }

    func match(
        transaction: Transaction,
        userId: UUID,
        on database: any Database
    ) async throws -> Match? {
        guard let transactionID = transaction.id,
              let quantity = transaction.quantity.map(abs),
              quantity > 0,
              ["BUY", "SELL"].contains(transaction.type.uppercased())
        else { return nil }
        let side = transaction.type.uppercased() == "SELL"
            ? TaxLocationLegSide.sell.rawValue
            : TaxLocationLegSide.buy.rawValue
        let candidates = try await TaxActionLegRecord.query(on: database)
            .filter(\.$accountId == transaction.accountId)
            .filter(\.$instrumentId == transaction.instrumentId)
            .filter(\.$side == side)
            .filter(\.$status == TaxActionLegStatus.planned.rawValue)
            .all()
        var eligible = [(TaxActionLegRecord, TaxActionPlan)]()
        for leg in candidates {
            guard let plan = try await TaxActionPlan.query(on: database)
                .filter(\.$id == leg.actionPlanId)
                .filter(\.$userId == userId)
                .first(),
                [TaxActionPlanStatus.accepted.rawValue, TaxActionPlanStatus.partiallyMatched.rawValue]
                .contains(plan.status),
                isWithinReconciliationWindow(transaction.tradeDate, plan.createdAt ?? transaction.tradeDate),
                quantitiesMatch(planned: leg.quantity, actual: quantity),
                notionalsMatch(leg: leg, transaction: transaction)
            else { continue }
            eligible.append((leg, plan))
        }
        guard eligible.count == 1, let legID = eligible[0].0.id, let planID = eligible[0].1.id else {
            if eligible.count > 1 {
                for (_, plan) in eligible {
                    plan.status = TaxActionPlanStatus.requiresReview.rawValue
                    try await plan.save(on: database)
                }
            }
            _ = transactionID
            return nil
        }
        let lotIDs = try JSONDecoder().decode([String].self, from: Data(eligible[0].0.lotIDsJSON.utf8))
            .compactMap(UUID.init(uuidString:))
        return Match(legID: legID, planID: planID, lotIDs: lotIDs)
    }

    func complete(
        _ match: Match?,
        transaction: Transaction,
        userId: UUID,
        on database: any Database
    ) async throws {
        guard let match, let transactionID = transaction.id,
              let leg = try await TaxActionLegRecord.find(match.legID, on: database),
              let plan = try await TaxActionPlan.query(on: database)
              .filter(\.$id == match.planID)
              .filter(\.$userId == userId)
              .first()
        else {
            if transaction.type.uppercased() == "BUY" {
                try await detectRestrictionViolation(transaction: transaction, userId: userId, on: database)
            }
            return
        }
        leg.status = TaxActionLegStatus.matched.rawValue
        leg.matchedTransactionId = transactionID
        try await leg.save(on: database)
        if transaction.type.uppercased() == "SELL" {
            try await createRestrictionWindow(userId: userId, leg: leg, date: transaction.tradeDate, on: database)
        } else {
            try await detectRestrictionViolation(transaction: transaction, userId: userId, on: database)
        }
        let planLegs = try await TaxActionLegRecord.query(on: database)
            .filter(\.$actionPlanId == match.planID)
            .all()
        if planLegs.allSatisfy({ $0.status == TaxActionLegStatus.matched.rawValue }) {
            plan.status = TaxActionPlanStatus.completed.rawValue
            plan.executedAt = transaction.tradeDate
        } else {
            plan.status = TaxActionPlanStatus.partiallyMatched.rawValue
        }
        try await plan.save(on: database)
    }

    private func quantitiesMatch(planned: Double?, actual: Double) -> Bool {
        guard let planned, planned > 0 else { return true }
        return abs(planned - actual) / planned <= 0.005
    }

    private func notionalsMatch(leg: TaxActionLegRecord, transaction: Transaction) -> Bool {
        guard leg.quantity == nil,
              let quantity = transaction.quantity.map(abs),
              let price = transaction.price,
              leg.notional > 0
        else { return true }
        return abs(leg.notional - quantity * price) / leg.notional <= 0.02
    }

    private func isWithinReconciliationWindow(_ tradeDate: Date, _ createdAt: Date) -> Bool {
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: createdAt, to: tradeDate).day ?? 0
        return (-1 ... 35).contains(days)
    }

    private func createRestrictionWindow(
        userId: UUID,
        leg: TaxActionLegRecord,
        date: Date,
        on database: any Database
    ) async throws {
        guard try await TaxRestrictionWindow.query(on: database)
            .filter(\.$actionLegId == leg.id!)
            .first() == nil,
            let account = try await Account.find(leg.accountId, on: database),
            account.userId == userId,
            account.taxJurisdiction == TaxJurisdiction.unitedStates.rawValue,
            let instrument = try await Instrument.find(leg.instrumentId, on: database)
        else { return }
        let calendar = Calendar(identifier: .gregorian)
        let window = TaxRestrictionWindow()
        window.userId = userId
        window.actionLegId = leg.id!
        window.jurisdiction = TaxJurisdiction.unitedStates.rawValue
        window.taxIdentityKey = identityKey(instrument)
        window.startsAt = calendar.date(byAdding: .day, value: -30, to: date)!
        window.endsAt = calendar.date(byAdding: .day, value: 30, to: date)!
        window.status = "active"
        try await window.create(on: database)
        try await detectExistingRestrictionViolation(
            window: window,
            identityKey: window.taxIdentityKey,
            userId: userId,
            on: database
        )
    }

    private func detectExistingRestrictionViolation(
        window: TaxRestrictionWindow,
        identityKey: String,
        userId: UUID,
        on database: any Database
    ) async throws {
        let accountIDs = try await Account.query(on: database)
            .filter(\.$userId == userId)
            .all()
            .compactMap(\.id)
        guard !accountIDs.isEmpty else { return }
        let purchases = try await Transaction.query(on: database)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$type == "BUY")
            .filter(\.$tradeDate >= window.startsAt)
            .filter(\.$tradeDate <= window.endsAt)
            .all()
        let instrumentIDs = Array(Set(purchases.map(\.instrumentId)))
        let instruments = instrumentIDs.isEmpty ? [] : try await Instrument.query(on: database)
            .filter(\.$id ~~ instrumentIDs)
            .all()
        let matchingIDs = Set(instruments.compactMap { instrument in
            instrument.id.flatMap { self.identityKey(instrument) == identityKey ? $0 : nil }
        })
        guard let violation = purchases
            .filter({ matchingIDs.contains($0.instrumentId) })
            .sorted(by: { $0.tradeDate < $1.tradeDate })
            .first,
            let transactionID = violation.id
        else { return }
        window.status = "violated"
        window.violatingTransactionId = transactionID
        try await window.save(on: database)
    }

    private func detectRestrictionViolation(
        transaction: Transaction,
        userId: UUID,
        on database: any Database
    ) async throws {
        guard let transactionID = transaction.id,
              let account = try await Account.find(transaction.accountId, on: database),
              account.userId == userId,
              let instrument = try await Instrument.find(transaction.instrumentId, on: database)
        else { return }
        let windows = try await TaxRestrictionWindow.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$taxIdentityKey == identityKey(instrument))
            .filter(\.$status == "active")
            .filter(\.$startsAt <= transaction.tradeDate)
            .filter(\.$endsAt >= transaction.tradeDate)
            .all()
        for window in windows {
            window.status = "violated"
            window.violatingTransactionId = transactionID
            try await window.save(on: database)
        }
    }

    private func identityKey(_ instrument: Instrument) -> String {
        instrument.taxIdentityGroup
            ?? instrument.cusip
            ?? instrument.isin
            ?? instrument.symbol.uppercased()
    }
}
