import Foundation
import StockPlanShared
import Vapor

struct MarketProviderQuote {
    let symbol: String
    let price: Double // Note: Maps to `c` in Finnhub
    let change: Double?
    let percentChange: Double?
    let high: Double?
    let low: Double?
    let open: Double?
    let previousClose: Double?
    let currency: String
    let asOf: Date
}

struct MarketProviderPriceBar {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int?
}

struct MarketProviderHistory {
    let symbol: String
    let currency: String
    let bars: [MarketProviderPriceBar]
}

struct MarketProviderSearchResult {
    let symbol: String
    let name: String
    let exchange: String
    let currency: String
    let conid: String
}

struct MarketProviderFxRate {
    let base: String
    let quote: String
    let rate: Double
    let asOf: Date
}

struct MarketProviderCompanyProfile {
    let symbol: String
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

struct MarketProviderBasicFinancials {
    let symbol: String
    let metricType: String
    let metric: [String: BasicFinancialMetricValue]
    let series: [String: [String: [BasicFinancialSeriesPoint]]]
}

protocol MarketDataProvider: Sendable {
    var name: String { get }

    func quote(symbol: String, on req: Request) async throws -> MarketProviderQuote
    func history(symbol: String, from: Date?, to: Date?, on req: Request) async throws
        -> MarketProviderHistory
    func search(query: String, on req: Request) async throws -> [MarketProviderSearchResult]
    func fx(base: String, quote: String, on req: Request) async throws -> MarketProviderFxRate
    func profile(symbol: String, on req: Request) async throws -> MarketProviderCompanyProfile?
    func basicFinancials(symbol: String, on req: Request) async throws -> MarketProviderBasicFinancials?
}
