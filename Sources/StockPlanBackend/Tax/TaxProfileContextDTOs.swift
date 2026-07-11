import Foundation
import StockPlanShared
import Vapor

struct TaxProfileAccountOption: Content {
    let id: String
    let displayName: String
    let broker: String
    let baseCurrency: String
    let wrapper: TaxAccountWrapper
    let ownerMemberId: String?
    let lotSelectionMethod: TaxLotSelectionMethod
}

struct TaxProfileContextResponse: Content {
    let jurisdiction: TaxJurisdiction
    let taxYear: Int
    let defaultReportingCurrency: String
    let profile: TaxProfileResponse?
    let accounts: [TaxProfileAccountOption]
}
