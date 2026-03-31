import Vapor
import StockPlanShared

typealias EarningsQueryRequest = StockPlanShared.EarningsQueryRequest
typealias EarningsItemResponse = StockPlanShared.EarningsItemResponse

extension EarningsQueryRequest: Content {}
extension EarningsItemResponse: Content {}

struct FinnhubEarningsPayload: Decodable {
    let earningsCalendar: [FinnhubEarningsItem]?
}

struct FinnhubEarningsItem: Decodable {
    let date: String?
    let epsActual: Double?
    let epsEstimate: Double?
    let hour: String?
    let quarter: Int?
    let revenueActual: Double?
    let revenueEstimate: Double?
    let symbol: String?
    let year: Int?
}
