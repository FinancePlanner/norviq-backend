import StockPlanShared
import Vapor

extension TaxProfileRequest: @retroactive Content {}
extension TaxProfileResponse: @retroactive Content {}
extension TaxProfileContextResponse: @retroactive Content {}
extension TaxInstrumentMarketOption: @retroactive Content {}
extension TaxFundClassificationRequest: @retroactive Content {}
extension TaxFundAnnualInputRequest: @retroactive Content {}
extension TaxFundAdvanceLumpSumResponse: @retroactive Content {}
extension TaxCapabilitiesResponse: @retroactive Content {}
extension TaxDashboardResponse: @retroactive Content {}
extension TaxScenarioRequest: @retroactive Content {}
extension TaxScenarioResponse: @retroactive Content {}
extension TaxActionPlanRequest: @retroactive Content {}
extension TaxActionPlanResponse: @retroactive Content {}
extension TaxActionPlanTransitionRequest: @retroactive Content {}
extension TaxLocationScenarioRequest: @retroactive Content {}
extension TaxLocationScenarioResponse: @retroactive Content {}
extension TaxPlacementPlanRequest: @retroactive Content {}
extension TaxReportRequest: @retroactive Content {}
extension TaxReportResponse: @retroactive Content {}
extension TaxLossCarryforwardApplicationResponse: @retroactive Content {}
extension TaxLossCarryforwardBalanceResponse: @retroactive Content {}
extension TaxLossCarryforwardLedgerResponse: @retroactive Content {}
extension TaxNotificationPreferences: @retroactive Content {}
