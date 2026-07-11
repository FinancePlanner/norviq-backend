import Fluent
import Foundation
import StockPlanShared
import Vapor

struct TaxNotificationPolicy: Sendable {
    func threshold(taxablePortfolioValue: Decimal, configuredMinimum: Decimal?) -> Decimal {
        max(Decimal(250), max(taxablePortfolioValue * Decimal(string: "0.005")!, configuredMinimum ?? 0))
    }

    func shouldNotify(
        benefit: Decimal,
        threshold: Decimal,
        previousBenefit: Decimal?
    ) -> Bool {
        guard benefit >= threshold else { return false }
        guard let previousBenefit else { return true }
        return benefit >= previousBenefit * Decimal(string: "1.25")!
    }
}

struct TaxNotificationEvaluator: Sendable {
    private let policy = TaxNotificationPolicy()
    func evaluate(
        dashboard: TaxDashboardResponse,
        userId: UUID,
        req: Request
    ) async throws {
        guard let preferences = try await TaxNotificationPreference.query(on: req.db)
            .filter(\.$userId == userId)
            .first(), preferences.enabled
        else { return }
        let accountIDs = try await Account.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$taxWrapper == TaxAccountWrapper.taxable.rawValue)
            .all()
            .compactMap(\.id)
        let positions = accountIDs.isEmpty ? [] : try await Position.query(on: req.db)
            .filter(\.$accountId ~~ accountIDs)
            .all()
        let taxableValue = positions.reduce(0.0) { partial, position in
            partial + max(0, position.quantity * (position.lastPrice ?? position.averageCost))
        }
        let configuredThreshold = preferences.minimumBenefit.map { Decimal($0) } ?? 0
        let threshold = policy.threshold(
            taxablePortfolioValue: Decimal(taxableValue),
            configuredMinimum: configuredThreshold
        )
        let devices = try await req.pushDeviceService.activeDevices(userId: userId, on: req.db)
        guard !devices.isEmpty else { return }

        for opportunity in dashboard.opportunities
            where opportunity.status == .actionable && opportunity.estimatedTaxBenefit.amount >= threshold
        {
            guard let instrumentID = UUID(uuidString: opportunity.instrumentId) else { continue }
            let cooldownStart = Calendar.current.date(
                byAdding: .day,
                value: -max(1, preferences.cooldownDays),
                to: Date()
            )!
            let previous = try await TaxNotificationDelivery.query(on: req.db)
                .filter(\.$userId == userId)
                .filter(\.$instrumentId == instrumentID)
                .filter(\.$deliveredAt >= cooldownStart)
                .sort(\.$deliveredAt, .descending)
                .first()
            let benefit = NSDecimalNumber(decimal: opportunity.estimatedTaxBenefit.amount).doubleValue
            guard policy.shouldNotify(
                benefit: opportunity.estimatedTaxBenefit.amount,
                threshold: threshold,
                previousBenefit: previous.map { Decimal($0.estimatedBenefit) }
            ) else { continue }
            let summary = await req.application.pushNotificationSender.sendTaxOpportunity(
                opportunity: opportunity,
                devices: devices,
                req: req
            )
            guard summary.delivered > 0 else { continue }
            let delivery = TaxNotificationDelivery()
            delivery.userId = userId
            delivery.opportunityId = opportunity.id
            delivery.instrumentId = instrumentID
            delivery.estimatedBenefit = benefit
            delivery.currency = opportunity.estimatedTaxBenefit.currency
            delivery.deliveredAt = Date()
            try await delivery.create(on: req.db)
        }
    }
}
