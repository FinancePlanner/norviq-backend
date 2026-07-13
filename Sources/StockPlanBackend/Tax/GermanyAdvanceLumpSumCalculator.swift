import Foundation
import StockPlanShared

struct GermanyAdvanceLumpSumInput: Equatable, Sendable {
    let calculationYear: Int
    let beginningMarketValue: Decimal
    let endingMarketValue: Decimal
    let distributions: Decimal
    let acquisitionMonth: Int?
    let fundClassification: TaxFundClassification
}

struct GermanyAdvanceLumpSumResult: Equatable, Sendable {
    let calculationYear: Int
    let deemedReceiptTaxYear: Int
    let basisRate: Decimal
    let baseYield: Decimal
    let appreciationCap: Decimal
    let acquisitionYearFactor: Decimal
    let grossAdvanceLumpSum: Decimal
    let partialExemptionRate: Decimal
    let taxableAdvanceLumpSum: Decimal
}

enum GermanyAdvanceLumpSumError: Error, Equatable {
    case unsupportedCalculationYear(Int)
    case invalidMarketValue
    case invalidDistributions
    case invalidAcquisitionMonth
    case unknownFundClassification
}

enum GermanyAdvanceLumpSumRateRegistry {
    static func basisRate(for calculationYear: Int) -> Decimal? {
        switch calculationYear {
        case 2025: 0.0253
        case 2026: 0.0320
        default: nil
        }
    }
}

enum GermanyAdvanceLumpSumCalculator {
    static func calculate(_ input: GermanyAdvanceLumpSumInput) throws -> GermanyAdvanceLumpSumResult {
        guard let basisRate = GermanyAdvanceLumpSumRateRegistry.basisRate(for: input.calculationYear) else {
            throw GermanyAdvanceLumpSumError.unsupportedCalculationYear(input.calculationYear)
        }
        guard input.beginningMarketValue >= 0, input.endingMarketValue >= 0 else {
            throw GermanyAdvanceLumpSumError.invalidMarketValue
        }
        guard input.distributions >= 0 else {
            throw GermanyAdvanceLumpSumError.invalidDistributions
        }
        if let month = input.acquisitionMonth, !(1 ... 12).contains(month) {
            throw GermanyAdvanceLumpSumError.invalidAcquisitionMonth
        }
        guard let exemptionRate = GermanyFundPartialExemptionCalculator.exemptionRate(
            for: input.fundClassification
        ) else {
            throw GermanyAdvanceLumpSumError.unknownFundClassification
        }

        let baseYield = max(0, input.beginningMarketValue * 0.70 * basisRate)
        let appreciationCap = max(
            0,
            input.endingMarketValue - input.beginningMarketValue + input.distributions
        )
        let distributionAdjustedAmount = max(0, min(baseYield, appreciationCap) - input.distributions)
        let acquisitionFactor: Decimal = if let month = input.acquisitionMonth {
            Decimal(13 - month) / 12
        } else {
            1
        }
        let grossAdvanceLumpSum = distributionAdjustedAmount * acquisitionFactor
        let taxableAdvanceLumpSum = grossAdvanceLumpSum * (1 - exemptionRate)

        return GermanyAdvanceLumpSumResult(
            calculationYear: input.calculationYear,
            deemedReceiptTaxYear: input.calculationYear + 1,
            basisRate: basisRate,
            baseYield: baseYield,
            appreciationCap: appreciationCap,
            acquisitionYearFactor: acquisitionFactor,
            grossAdvanceLumpSum: grossAdvanceLumpSum,
            partialExemptionRate: exemptionRate,
            taxableAdvanceLumpSum: taxableAdvanceLumpSum
        )
    }
}
