import Vapor

struct QuoteResponse: Content {
    let symbol: String
    let price: Double
    let currency: String
    let asOf: String
}

struct PriceBarResponse: Content {
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int?
}

struct HistoryResponse: Content {
    let symbol: String
    let currency: String
    let bars: [PriceBarResponse]
}

struct SearchResultResponse: Content {
    let symbol: String
    let name: String
    let exchange: String
    let currency: String
    let conid: String
}

struct FxRateResponse: Content {
    let base: String
    let quote: String
    let rate: Double
    let date: String
}
