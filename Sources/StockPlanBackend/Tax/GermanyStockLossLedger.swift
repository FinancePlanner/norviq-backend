import Fluent
import Foundation
import StockPlanShared

final class GermanyStockLossYear: Model, @unchecked Sendable {
    static let schema = "germany_stock_loss_years"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "tax_year") var taxYear: Int
    @Field(key: "net_stock_result") var netStockResult: Double
    @Field(key: "loss_generated") var lossGenerated: Double
    @Field(key: "prior_loss_applied") var priorLossApplied: Double
    @Field(key: "taxable_stock_gain") var taxableStockGain: Double
    @Field(key: "ending_loss_carryforward") var endingLossCarryforward: Double
    @Field(key: "rule_version") var ruleVersion: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userId: UUID, taxYear: Int, netStockResult: Decimal, ruleVersion: String) {
        self.userId = userId
        self.taxYear = taxYear
        self.netStockResult = NSDecimalNumber(decimal: netStockResult).doubleValue
        lossGenerated = 0
        priorLossApplied = 0
        taxableStockGain = 0
        endingLossCarryforward = 0
        self.ruleVersion = ruleVersion
    }
}

struct GermanyStockLossLedgerResult: Equatable, Sendable {
    let taxYear: Int
    let netStockResult: Decimal
    let lossGenerated: Decimal
    let priorLossApplied: Decimal
    let taxableStockGain: Decimal
    let endingLossCarryforward: Decimal
}

struct GermanyStockLossLedger: Sendable {
    func response(
        userId: UUID,
        asOfTaxYear: Int,
        on database: any Database
    ) async throws -> TaxLossCarryforwardLedgerResponse {
        let years = try await GermanyStockLossYear.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$taxYear <= asOfTaxYear)
            .sort(\.$taxYear, .ascending)
            .all()

        var remainingByYear = [Int: Decimal]()
        for year in years {
            var gain = max(0, Decimal(year.netStockResult))
            for sourceYear in remainingByYear.keys.sorted() where gain > 0 {
                let available = remainingByYear[sourceYear] ?? 0
                let applied = min(gain, available)
                remainingByYear[sourceYear] = available - applied
                gain -= applied
            }
            let generated = max(0, -Decimal(year.netStockResult))
            if generated > 0 {
                remainingByYear[year.taxYear, default: 0] += generated
            }
        }

        let balances = years.compactMap { year -> TaxLossCarryforwardBalanceResponse? in
            let generated = max(0, -Decimal(year.netStockResult))
            guard generated > 0, let id = year.id else { return nil }
            return TaxLossCarryforwardBalanceResponse(
                id: id.uuidString,
                jurisdiction: .germany,
                sourceTaxYear: year.taxYear,
                expiresAfterTaxYear: 9999,
                originalAmount: TaxMoney(amount: generated, currency: "EUR"),
                remainingAmount: TaxMoney(amount: remainingByYear[year.taxYear] ?? 0, currency: "EUR"),
                ruleVersion: year.ruleVersion,
                applications: []
            )
        }
        let total = balances.reduce(Decimal.zero) { $0 + $1.remainingAmount.amount }
        return TaxLossCarryforwardLedgerResponse(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            jurisdiction: .germany,
            asOfTaxYear: asOfTaxYear,
            totalAvailable: TaxMoney(amount: total, currency: "EUR"),
            balances: balances
        )
    }

    func reconcile(
        userId: UUID,
        taxYear: Int,
        netStockResult: Decimal,
        ruleVersion: String,
        on database: any Database
    ) async throws -> GermanyStockLossLedgerResult {
        try await database.transaction { transaction in
            let storedYear = try await GermanyStockLossYear.query(on: transaction)
                .filter(\.$userId == userId)
                .filter(\.$taxYear == taxYear)
                .first()
                ?? GermanyStockLossYear(
                    userId: userId,
                    taxYear: taxYear,
                    netStockResult: netStockResult,
                    ruleVersion: ruleVersion
                )

            storedYear.netStockResult = NSDecimalNumber(decimal: netStockResult).doubleValue
            storedYear.ruleVersion = ruleVersion
            try await storedYear.save(on: transaction)

            let years = try await GermanyStockLossYear.query(on: transaction)
                .filter(\.$userId == userId)
                .sort(\.$taxYear, .ascending)
                .all()

            var carryforward: Decimal = 0
            var requestedResult: GermanyStockLossLedgerResult?

            for year in years {
                let annualResult = Decimal(year.netStockResult)
                let gain = max(0, annualResult)
                let generatedLoss = max(0, -annualResult)
                let appliedLoss = min(gain, carryforward)
                let taxableGain = gain - appliedLoss
                carryforward = carryforward - appliedLoss + generatedLoss

                year.lossGenerated = NSDecimalNumber(decimal: generatedLoss).doubleValue
                year.priorLossApplied = NSDecimalNumber(decimal: appliedLoss).doubleValue
                year.taxableStockGain = NSDecimalNumber(decimal: taxableGain).doubleValue
                year.endingLossCarryforward = NSDecimalNumber(decimal: carryforward).doubleValue
                try await year.save(on: transaction)

                if year.taxYear == taxYear {
                    requestedResult = GermanyStockLossLedgerResult(
                        taxYear: year.taxYear,
                        netStockResult: annualResult,
                        lossGenerated: generatedLoss,
                        priorLossApplied: appliedLoss,
                        taxableStockGain: taxableGain,
                        endingLossCarryforward: carryforward
                    )
                }
            }

            guard let requestedResult else {
                throw GermanyStockLossLedgerError.reconciliationResultMissing
            }
            return requestedResult
        }
    }

    func balance(userId: UUID, through taxYear: Int, on database: any Database) async throws -> Decimal {
        let stored = try await GermanyStockLossYear.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$taxYear <= taxYear)
            .sort(\.$taxYear, .descending)
            .first()
        return stored.map { Decimal($0.endingLossCarryforward) } ?? 0
    }
}

enum GermanyStockLossLedgerError: Error {
    case reconciliationResultMissing
}
