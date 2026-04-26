import Foundation
import Vapor

struct MarketDataProviderDisabledError: AbortError {
    let status: HTTPResponseStatus = .serviceUnavailable
    let reason = "Market data provider is disabled."
}

struct DisabledMarketDataProvider: MarketDataProvider {
    var name: String {
        "disabled"
    }

    func quote(symbol: String, on _: Request) async throws -> MarketProviderQuote {
        MarketProviderQuote(symbol: symbol, price: 0, change: nil, percentChange: nil, high: nil, low: nil, open: nil, previousClose: nil, currency: "USD", asOf: Date())
    }

    func history(symbol _: String, from _: Date?, to _: Date?, on _: Request) async throws
        -> MarketProviderHistory
    {
        throw MarketDataProviderDisabledError()
    }

    func search(query _: String, on _: Request) async throws -> [MarketProviderSearchResult] {
        throw MarketDataProviderDisabledError()
    }

    func fx(base _: String, quote _: String, on _: Request) async throws -> MarketProviderFxRate {
        throw MarketDataProviderDisabledError()
    }

    func profile(symbol _: String, on _: Request) async throws -> MarketProviderCompanyProfile? {
        throw MarketDataProviderDisabledError()
    }

    func basicFinancials(symbol _: String, on _: Request) async throws -> MarketProviderBasicFinancials? {
        throw MarketDataProviderDisabledError()
    }
}
