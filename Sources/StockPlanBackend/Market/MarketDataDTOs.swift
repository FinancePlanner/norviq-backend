import Vapor

struct StockDetailsResponse: Content {
    let symbol: String
    let company: String
    let latestPrice: Double
    let changePercent: Double
}

struct QuoteResponse: Content {
    let symbol: String
    let currency: String
    let c: Double
    let d: Double?
    let dp: Double?
    let h: Double?
    let l: Double?
    let o: Double?
    let pc: Double?
    let t: Int
}

struct CompanyProfileResponse: Content {
    let country: String?
    let currency: String?
    let estimateCurrency: String?
    let exchange: String?
    let finnhubIndustry: String?
    let ipo: String?
    let logo: String?
    let marketCapitalization: Double?
    let name: String?
    let phone: String?
    let shareOutstanding: Double?
    let ticker: String?
    let weburl: String?
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

struct QuoteBatchResponse: Content {
    let quotes: [QuoteResponse]
}
