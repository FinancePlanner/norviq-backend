import Foundation
import Vapor

struct MarketProviderQuote: Sendable {
    let symbol: String
    let price: Double  // Note: Maps to `c` in Finnhub
    let change: Double?
    let percentChange: Double?
    let high: Double?
    let low: Double?
    let open: Double?
    let previousClose: Double?
    let currency: String
    let asOf: Date
}

struct MarketProviderPriceBar: Sendable {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int?
}

struct MarketProviderHistory: Sendable {
    let symbol: String
    let currency: String
    let bars: [MarketProviderPriceBar]
}

struct MarketProviderSearchResult: Sendable {
    let symbol: String
    let name: String
    let exchange: String
    let currency: String
    let conid: String
}

struct MarketProviderFxRate: Sendable {
    let base: String
    let quote: String
    let rate: Double
    let asOf: Date
}

struct MarketProviderCompanyProfile: Sendable {
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

protocol MarketDataProvider: Sendable {
    var name: String { get }

    func quote(symbol: String, on req: Request) async throws -> MarketProviderQuote
    func history(symbol: String, from: Date?, to: Date?, on req: Request) async throws
        -> MarketProviderHistory
    func search(query: String, on req: Request) async throws -> [MarketProviderSearchResult]
    func fx(base: String, quote: String, on req: Request) async throws -> MarketProviderFxRate
    func profile(symbol: String, on req: Request) async throws -> MarketProviderCompanyProfile?
}
