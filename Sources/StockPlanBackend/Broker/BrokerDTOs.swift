import Vapor
import StockPlanShared

typealias BrokerConnectionResponse = StockPlanShared.BrokerConnectionResponse
typealias BrokerHoldingResponse = StockPlanShared.BrokerHoldingResponse
typealias BrokerSyncResponse = StockPlanShared.BrokerSyncResponse

extension BrokerConnectionResponse: Content {}
extension BrokerHoldingResponse: Content {}
extension BrokerSyncResponse: Content {}
