import Foundation
import StockPlanShared

enum GermanyFundPartialExemptionCalculator {
    static func exemptionRate(for classification: TaxFundClassification) -> Decimal? {
        switch classification {
        case .equity: 0.30
        case .mixed: 0.15
        case .realEstate: 0.60
        case .foreignRealEstate: 0.80
        case .other: 0
        case .unknown: nil
        }
    }

    static func taxableAmount(
        _ amount: Decimal,
        classification: TaxFundClassification
    ) -> Decimal? {
        exemptionRate(for: classification).map { amount * (1 - $0) }
    }
}
