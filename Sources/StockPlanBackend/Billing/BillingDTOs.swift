import StockPlanShared
import Vapor

extension BillingContextResponse: @retroactive Content {}
extension BillingSubscriptionDTO: @retroactive Content {}
extension BillingFeatureDTO: @retroactive Content {}
extension BillingUsageDTO: @retroactive Content {}
extension BillingUpgradeRequiredResponse: @retroactive Content {}
