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
            estimatedTax: taxableGain * combinedRate
        )
    }
}
