import StockPlanShared
import Vapor

extension TaxProfileRequest: @retroactive Content {}
extension TaxProfileResponse: @retroactive Content {}
extension TaxProfileContextResponse: @retroactive Content {}
extension TaxInstrumentMarketOption: @retroactive Content {}
extension TaxCapabilitiesResponse: @retroactive Content {}
extension TaxDashboardResponse: @retroactive Content {}
extension TaxScenarioRequest: @retroactive Content {}
extension TaxScenarioResponse: @retroactive Content {}
extension TaxActionPlanRequest: @retroactive Content {}
extension TaxActionPlanResponse: @retroactive Content {}
extension TaxReportRequest: @retroactive Content {}
extension TaxReportResponse: @retroactive Content {}
extension TaxNotificationPreferences: @retroactive Content {}
