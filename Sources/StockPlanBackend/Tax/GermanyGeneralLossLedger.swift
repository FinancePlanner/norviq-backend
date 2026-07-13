import Fluent
import Foundation
import StockPlanShared

final class GermanyGeneralLossYear: Model, @unchecked Sendable {
    static let schema = "germany_general_loss_years"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "tax_year") var taxYear: Int
    @Field(key: "net_capital_result") var netCapitalResult: Double
    @Field(key: "loss_generated") var lossGenerated: Double
    @Field(key: "prior_loss_applied") var priorLossApplied: Double
    @Field(key: "taxable_capital_gain") var taxableCapitalGain: Double
    @Field(key: "ending_loss_carryforward") var endingLossCarryforward: Double
    @Field(key: "rule_version") var ruleVersion: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userId: UUID, taxYear: Int, netCapitalResult: Decimal, ruleVersion: String) {
        self.userId = userId
        self.taxYear = taxYear
        self.netCapitalResult = NSDecimalNumber(decimal: netCapitalResult).doubleValue
        lossGenerated = 0
        priorLossApplied = 0
        taxableCapitalGain = 0
        endingLossCarryforward = 0
        self.ruleVersion = ruleVersion
    }
}

final class GermanyGeneralLossApplication: Model, @unchecked Sendable {
    static let schema = "germany_general_loss_applications"

    @ID(key: .id) var id: UUID?
    @Field(key: "source_year_id") var sourceYearId: UUID
    @Field(key: "target_tax_year") var targetTaxYear: Int
    @Field(key: "amount") var amount: Double
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(sourceYearId: UUID, targetTaxYear: Int, amount: Decimal) {
        self.sourceYearId = sourceYearId
        self.targetTaxYear = targetTaxYear
        self.amount = NSDecimalNumber(decimal: amount).doubleValue
    }
}

struct GermanyGeneralLossLedgerResult: Equatable, Sendable {
    let taxYear: Int
    let netCapitalResult: Decimal
    let lossGenerated: Decimal
    let priorLossApplied: Decimal
    let taxableCapitalGain: Decimal
    let endingLossCarryforward: Decimal
}

struct GermanyGeneralLossLedger: Sendable {
    func balances(
        userId: UUID,
        asOfTaxYear: Int,
        on database: any Database
    ) async throws -> [TaxLossCarryforwardBalanceResponse] {
        let years = try await GermanyGeneralLossYear.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$taxYear <= asOfTaxYear)
            .sort(\.$taxYear, .ascending)
            .all()
        let yearIDs = years.compactMap(\.id)
        let applications = yearIDs.isEmpty ? [] : try await GermanyGeneralLossApplication.query(on: database)
            .filter(\.$sourceYearId ~~ yearIDs)
            .sort(\.$targetTaxYear, .ascending)
            .all()
        let applicationsBySource = Dictionary(grouping: applications, by: \.sourceYearId)

        return years.compactMap { year -> TaxLossCarryforwardBalanceResponse? in
            let generated = max(0, -Decimal(year.netCapitalResult))
            guard generated > 0, let id = year.id else { return nil }
            let sourceApplications = applicationsBySource[id] ?? []
            let applied = sourceApplications.reduce(Decimal.zero) { $0 + Decimal($1.amount) }
            return TaxLossCarryforwardBalanceResponse(
                id: id.uuidString,
                jurisdiction: .germany,
                sourceTaxYear: year.taxYear,
                expiresAfterTaxYear: 9999,
                originalAmount: TaxMoney(amount: generated, currency: "EUR"),
                remainingAmount: TaxMoney(amount: max(0, generated - applied), currency: "EUR"),
                ruleVersion: year.ruleVersion,
                category: .generalCapital,
                applications: sourceApplications.compactMap { application in
                    guard let applicationID = application.id else { return nil }
                    return TaxLossCarryforwardApplicationResponse(
                        id: applicationID.uuidString,
                        targetTaxYear: application.targetTaxYear,
                        amount: TaxMoney(amount: Decimal(application.amount), currency: "EUR"),
                        createdAt: ISO8601DateFormatter().string(from: application.createdAt ?? Date())
                    )
                }
            )
        }
    }

    func reconcile(
        userId: UUID,
        taxYear: Int,
        netCapitalResult: Decimal,
        ruleVersion: String,
        on database: any Database
    ) async throws -> GermanyGeneralLossLedgerResult {
        try await database.transaction { transaction in
            let storedYear = try await GermanyGeneralLossYear.query(on: transaction)
                .filter(\.$userId == userId)
                .filter(\.$taxYear == taxYear)
                .first()
                ?? GermanyGeneralLossYear(
                    userId: userId,
                    taxYear: taxYear,
                    netCapitalResult: netCapitalResult,
                    ruleVersion: ruleVersion
                )
            storedYear.netCapitalResult = NSDecimalNumber(decimal: netCapitalResult).doubleValue
            storedYear.ruleVersion = ruleVersion
            try await storedYear.save(on: transaction)

            let years = try await GermanyGeneralLossYear.query(on: transaction)
                .filter(\.$userId == userId)
                .sort(\.$taxYear, .ascending)
                .all()
            let yearIDs = years.compactMap(\.id)
            let existingApplications = yearIDs.isEmpty ? [] : try await GermanyGeneralLossApplication.query(on: transaction)
                .filter(\.$sourceYearId ~~ yearIDs)
                .all()
            let existingByKey = Dictionary(uniqueKeysWithValues: existingApplications.map {
                ("\($0.sourceYearId.uuidString):\($0.targetTaxYear)", $0)
            })
            var retainedApplicationIDs = Set<UUID>()
            var lossBuckets = [(sourceYearId: UUID, remaining: Decimal)]()
            var requestedResult: GermanyGeneralLossLedgerResult?

            for year in years {
                let annualResult = Decimal(year.netCapitalResult)
                let gain = max(0, annualResult)
                let generatedLoss = max(0, -annualResult)
                var remainingGain = gain
                var appliedLoss: Decimal = 0

                for index in lossBuckets.indices where remainingGain > 0 {
                    let amount = min(remainingGain, lossBuckets[index].remaining)
                    guard amount > 0 else { continue }
                    lossBuckets[index].remaining -= amount
                    remainingGain -= amount
                    appliedLoss += amount

                    let sourceYearID = lossBuckets[index].sourceYearId
                    let key = "\(sourceYearID.uuidString):\(year.taxYear)"
                    let application = existingByKey[key]
                        ?? GermanyGeneralLossApplication(
                            sourceYearId: sourceYearID,
                            targetTaxYear: year.taxYear,
                            amount: amount
                        )
                    application.amount = NSDecimalNumber(decimal: amount).doubleValue
                    try await application.save(on: transaction)
                    if let applicationID = application.id {
                        retainedApplicationIDs.insert(applicationID)
                    }
                }

                let taxableGain = gain - appliedLoss
                if generatedLoss > 0, let yearID = year.id {
                    lossBuckets.append((sourceYearId: yearID, remaining: generatedLoss))
                }
                let carryforward = lossBuckets.reduce(Decimal.zero) { $0 + $1.remaining }
                year.lossGenerated = NSDecimalNumber(decimal: generatedLoss).doubleValue
                year.priorLossApplied = NSDecimalNumber(decimal: appliedLoss).doubleValue
                year.taxableCapitalGain = NSDecimalNumber(decimal: taxableGain).doubleValue
                year.endingLossCarryforward = NSDecimalNumber(decimal: carryforward).doubleValue
                try await year.save(on: transaction)

                if year.taxYear == taxYear {
                    requestedResult = GermanyGeneralLossLedgerResult(
                        taxYear: year.taxYear,
                        netCapitalResult: annualResult,
                        lossGenerated: generatedLoss,
                        priorLossApplied: appliedLoss,
                        taxableCapitalGain: taxableGain,
                        endingLossCarryforward: carryforward
                    )
                }
            }

            for application in existingApplications {
                guard let applicationID = application.id,
                      !retainedApplicationIDs.contains(applicationID)
                else { continue }
                try await application.delete(on: transaction)
            }
            guard let requestedResult else {
                throw GermanyGeneralLossLedgerError.reconciliationResultMissing
            }
            return requestedResult
        }
    }
}

enum GermanyGeneralLossLedgerError: Error {
    case reconciliationResultMissing
}
