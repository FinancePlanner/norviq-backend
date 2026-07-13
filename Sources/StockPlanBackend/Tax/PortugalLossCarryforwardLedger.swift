import Fluent
import Foundation
import StockPlanShared

struct PortugalLossCarryforwardLedger: Sendable {
    func response(
        userId: UUID,
        jurisdiction: TaxJurisdiction,
        asOfTaxYear: Int,
        on database: any Database
    ) async throws -> TaxLossCarryforwardLedgerResponse {
        let balances = try await TaxLossCarryforward.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == jurisdiction.rawValue)
            .filter(\.$sourceTaxYear <= asOfTaxYear)
            .sort(\.$sourceTaxYear, .descending)
            .all()
        let ids = balances.compactMap(\.id)
        let applications = ids.isEmpty ? [] : try await TaxLossCarryforwardApplication.query(on: database)
            .filter(\.$carryforwardId ~~ ids)
            .sort(\.$targetTaxYear)
            .all()
        let applicationsByBalance = Dictionary(grouping: applications, by: \.carryforwardId)
        let rows = balances.compactMap { balance -> TaxLossCarryforwardBalanceResponse? in
            guard let id = balance.id else { return nil }
            return TaxLossCarryforwardBalanceResponse(
                id: id.uuidString,
                jurisdiction: jurisdiction,
                sourceTaxYear: balance.sourceTaxYear,
                expiresAfterTaxYear: balance.expiresAfterTaxYear,
                originalAmount: TaxMoney(amount: Decimal(balance.originalAmount), currency: balance.currency),
                remainingAmount: TaxMoney(amount: Decimal(balance.remainingAmount), currency: balance.currency),
                ruleVersion: balance.ruleVersion,
                applications: (applicationsByBalance[id] ?? []).compactMap { application in
                    guard let applicationID = application.id else { return nil }
                    return TaxLossCarryforwardApplicationResponse(
                        id: applicationID.uuidString,
                        targetTaxYear: application.targetTaxYear,
                        amount: TaxMoney(amount: Decimal(application.amount), currency: balance.currency),
                        createdAt: isoTimestamp(application.createdAt)
                    )
                }
            )
        }
        let currency = balances.first?.currency ?? (jurisdiction == .unitedStates ? "USD" : "EUR")
        let totalAvailable = balances
            .filter { $0.sourceTaxYear < asOfTaxYear && $0.expiresAfterTaxYear >= asOfTaxYear }
            .reduce(Decimal.zero) { $0 + Decimal(max(0, $1.remainingAmount)) }
        return TaxLossCarryforwardLedgerResponse(
            generatedAt: isoTimestamp(Date()),
            jurisdiction: jurisdiction,
            asOfTaxYear: asOfTaxYear,
            totalAvailable: TaxMoney(amount: totalAvailable, currency: currency),
            balances: rows
        )
    }

    func available(
        userId: UUID,
        taxYear: Int,
        on database: any Database
    ) async throws -> Decimal {
        let balances = try await eligibleBalances(userId: userId, taxYear: taxYear, on: database)
        let ids = balances.compactMap(\.id)
        guard !ids.isEmpty else { return 0 }
        let applications = try await TaxLossCarryforwardApplication.query(on: database)
            .filter(\.$carryforwardId ~~ ids)
            .filter(\.$targetTaxYear < taxYear)
            .all()
        let appliedByBalance = Dictionary(grouping: applications, by: \.carryforwardId)
            .mapValues { values in values.reduce(0.0) { $0 + $1.amount } }
        return balances.reduce(Decimal.zero) { total, balance in
            guard let id = balance.id else { return total }
            return total + Decimal(max(0, balance.originalAmount - (appliedByBalance[id] ?? 0)))
        }
    }

    func reconcile(
        userId: UUID,
        taxYear: Int,
        currency: String,
        ruleVersion: String,
        result: PortugalCapitalGainsResult,
        on database: any Database
    ) async throws {
        let generatedForMetrics = result.aggregationApplied && result.annualBalance < 0
            ? -result.annualBalance
            : 0
        try await database.transaction { db in
            let balances = try await eligibleBalances(userId: userId, taxYear: taxYear, on: db)
                .sorted { ($0.sourceTaxYear, $0.id?.uuidString ?? "") < ($1.sourceTaxYear, $1.id?.uuidString ?? "") }
            let ids = balances.compactMap(\.id)
            if !ids.isEmpty {
                let priorApplications = try await TaxLossCarryforwardApplication.query(on: db)
                    .filter(\.$carryforwardId ~~ ids)
                    .filter(\.$targetTaxYear == taxYear)
                    .all()
                for application in priorApplications {
                    try await application.delete(on: db)
                }

                var amountToApply = max(0, NSDecimalNumber(decimal: result.appliedLossCarryforward).doubleValue)
                for balance in balances where amountToApply > 0 {
                    guard let balanceID = balance.id else { continue }
                    let earlierApplications = try await TaxLossCarryforwardApplication.query(on: db)
                        .filter(\.$carryforwardId == balanceID)
                        .filter(\.$targetTaxYear < taxYear)
                        .all()
                    let usedEarlier = earlierApplications.reduce(0.0) { $0 + $1.amount }
                    let available = max(0, balance.originalAmount - usedEarlier)
                    let applied = min(available, amountToApply)
                    guard applied > 0 else { continue }
                    let application = TaxLossCarryforwardApplication()
                    application.carryforwardId = balanceID
                    application.targetTaxYear = taxYear
                    application.amount = applied
                    try await application.create(on: db)
                    amountToApply -= applied
                }
            }

            let generatedLoss = result.aggregationApplied && result.annualBalance < 0
                ? NSDecimalNumber(decimal: -result.annualBalance).doubleValue
                : 0
            let current = try await TaxLossCarryforward.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$jurisdiction == TaxJurisdiction.portugal.rawValue)
                .filter(\.$sourceTaxYear == taxYear)
                .first() ?? TaxLossCarryforward()
            current.userId = userId
            current.jurisdiction = TaxJurisdiction.portugal.rawValue
            current.sourceTaxYear = taxYear
            current.expiresAfterTaxYear = taxYear + 5
            current.originalAmount = generatedLoss
            current.currency = currency.uppercased()
            current.ruleVersion = ruleVersion
            let consumedAmount: Double
            if let currentID = current.id {
                let applications = try await TaxLossCarryforwardApplication.query(on: db)
                    .filter(\.$carryforwardId == currentID)
                    .all()
                consumedAmount = applications.reduce(0.0) { $0 + $1.amount }
            } else {
                consumedAmount = 0
            }
            current.remainingAmount = max(0, generatedLoss - consumedAmount)
            try await current.save(on: db)

            for balance in balances {
                guard let balanceID = balance.id else { continue }
                let applications = try await TaxLossCarryforwardApplication.query(on: db)
                    .filter(\.$carryforwardId == balanceID)
                    .all()
                balance.remainingAmount = max(0, balance.originalAmount - applications.reduce(0.0) { $0 + $1.amount })
                try await balance.save(on: db)
            }
        }
        PrometheusMetrics.shared.recordTaxCarryforwardReconciliation(
            generated: generatedForMetrics,
            applied: result.appliedLossCarryforward
        )
    }

    private func eligibleBalances(
        userId: UUID,
        taxYear: Int,
        on database: any Database
    ) async throws -> [TaxLossCarryforward] {
        try await TaxLossCarryforward.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == TaxJurisdiction.portugal.rawValue)
            .filter(\.$sourceTaxYear < taxYear)
            .filter(\.$expiresAfterTaxYear >= taxYear)
            .all()
    }

    private func isoTimestamp(_ date: Date?) -> String {
        ISO8601DateFormatter().string(from: date ?? Date())
    }
}
