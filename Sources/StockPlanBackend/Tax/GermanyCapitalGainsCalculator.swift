import Foundation

struct GermanyCapitalGainsResult: Equatable, Sendable {
    let stockGains: Decimal
    let currentYearStockLosses: Decimal
    let priorStockLossApplied: Decimal
    let taxableStockGains: Decimal
    let endingStockLossCarryforward: Decimal
    let estimatedTax: Decimal
}

enum GermanyCapitalGainsCalculator {
    static let investmentIncomeTaxRate: Decimal = 0.25
    static let solidaritySurchargeRate: Decimal = 0.055
    static let combinedRate: Decimal = 0.26375

    static func estimatedTax(
        taxableStockGain: Decimal,
        remainingCapitalIncomeAllowance: Decimal?,
        churchTaxRate: Decimal?
    ) -> Decimal {
        let allowance = min(max(0, remainingCapitalIncomeAllowance ?? 0), max(0, taxableStockGain))
        let taxableAfterAllowance = max(0, taxableStockGain - allowance)
        let churchRate = max(0, churchTaxRate ?? 0)
        guard churchRate > 0 else { return taxableAfterAllowance * combinedRate }

        // EStG section 32d(1): church tax is deductible when calculating the
        // investment-income tax. Foreign-tax credits are handled separately.
        let investmentIncomeTax = taxableAfterAllowance / (4 + churchRate)
        return investmentIncomeTax * (1 + churchRate + solidaritySurchargeRate)
    }

    static func calculate(
        realizedStockResults: [Decimal],
        priorStockLossCarryforward: Decimal = 0
    ) -> GermanyCapitalGainsResult {
        let gains = realizedStockResults.filter { $0 > 0 }.reduce(0, +)
        let losses = realizedStockResults.filter { $0 < 0 }.reduce(0) { $0 + -$1 }
        let normalizedPriorLoss = max(0, priorStockLossCarryforward)
        let currentYearNetGain = max(0, gains - losses)
        let currentYearUnusedLoss = max(0, losses - gains)
        let priorLossApplied = min(currentYearNetGain, normalizedPriorLoss)
        let taxableGain = currentYearNetGain - priorLossApplied
        let endingCarryforward = normalizedPriorLoss - priorLossApplied + currentYearUnusedLoss

        return GermanyCapitalGainsResult(
            stockGains: gains,
            currentYearStockLosses: losses,
            priorStockLossApplied: priorLossApplied,
            taxableStockGains: taxableGain,
            endingStockLossCarryforward: endingCarryforward,
            estimatedTax: estimatedTax(
                taxableStockGain: taxableGain,
                remainingCapitalIncomeAllowance: nil,
                churchTaxRate: nil
            )
        )
    }
}
