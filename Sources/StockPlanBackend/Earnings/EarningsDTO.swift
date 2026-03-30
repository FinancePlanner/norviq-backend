import Vapor

struct EarningsQueryRequest: Content {
    let from: String?
    let to: String?
    let symbol: String?
    let international: Bool?
}

struct EarningsItemResponse: Content {
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
