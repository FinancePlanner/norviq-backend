import Foundation
import Vapor

struct MarketDataProviderDisabledError: AbortError {
    let status: HTTPResponseStatus = .serviceUnavailable
    let reason = "Market data provider is disabled."
}

struct DisabledMarketDataProvider: MarketDataProvider {
    var name: String { "disabled" }

    func quote(symbol: String, on req: Request) async throws -> MarketProviderQuote {
        return MarketProviderQuote(symbol: symbol, price: 0, change: nil, percentChange: nil, high: nil, low: nil, open: nil, previousClose: nil, currency: "USD", asOf: Date())
    }

    func history(symbol: String, from: Date?, to: Date?, on req: Request) async throws
        -> MarketProviderHistory {
        throw MarketDataProviderDisabledError()
    }

    func search(query: String, on req: Request) async throws -> [MarketProviderSearchResult] {
        throw MarketDataProviderDisabledError()
    }

    func fx(base: String, quote: String, on req: Request) async throws -> MarketProviderFxRate {
        throw MarketDataProviderDisabledError()
    }

    func profile(symbol: String, on req: Request) async throws -> MarketProviderCompanyProfile? {
        throw MarketDataProviderDisabledError()
    }

    func basicFinancials(symbol: String, on req: Request) async throws -> MarketProviderBasicFinancials? {
        throw MarketDataProviderDisabledError()
    }
}
