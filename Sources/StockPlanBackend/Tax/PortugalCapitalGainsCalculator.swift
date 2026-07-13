import Foundation
import StockPlanShared

struct PortugalRealizedPosition: Sendable, Equatable {
    let realizedPnL: Decimal
    let holdingDays: Int
}

struct PortugalCapitalGainsResult: Sendable, Equatable {
    let annualBalance: Decimal
    let taxableBalance: Decimal
    let appliedLossCarryforward: Decimal
    let remainingLossCarryforward: Decimal
    let estimatedTax: Decimal
    let appliedRate: Decimal
    let aggregationRequired: Bool
    let aggregationApplied: Bool
}

struct PortugalCapitalGainsCalculator: Sendable {
    static let autonomousRate: Decimal = 0.28
    static let topBandThreshold2026: Decimal = 86634

    func calculate(
        positions: [PortugalRealizedPosition],
        estimatedTaxableIncome: Decimal,
        marginalRate: Decimal,
        taxationMode: TaxCapitalGainsTaxationMode?,
        eligibleLossCarryforward: Decimal
    ) -> PortugalCapitalGainsResult {
        let annualBalance = positions.reduce(Decimal.zero) { $0 + $1.realizedPnL }
        let positiveBalance = max(0, annualBalance)
        let hasShortTermGain = positions.contains { $0.holdingDays < 365 && $0.realizedPnL > 0 }
        let aggregationRequired = hasShortTermGain
            && estimatedTaxableIncome + positiveBalance >= Self.topBandThreshold2026
        let aggregationApplied = aggregationRequired || taxationMode == .aggregateWithIncome
        let availableCarryforward = max(0, eligibleLossCarryforward)
        let appliedCarryforward = aggregationApplied ? min(positiveBalance, availableCarryforward) : 0
        let taxableBalance = max(0, positiveBalance - appliedCarryforward)
        let rate = aggregationApplied ? max(0, marginalRate) : Self.autonomousRate
        let currentEligibleLoss = aggregationApplied && annualBalance < 0 ? -annualBalance : 0
        let remainingCarryforward = max(0, availableCarryforward - appliedCarryforward) + currentEligibleLoss

        return PortugalCapitalGainsResult(
            annualBalance: annualBalance,
            taxableBalance: taxableBalance,
            appliedLossCarryforward: appliedCarryforward,
            remainingLossCarryforward: remainingCarryforward,
            estimatedTax: taxableBalance * rate,
            appliedRate: rate,
            aggregationRequired: aggregationRequired,
            aggregationApplied: aggregationApplied
        )
    }
}
