import Foundation
import Vapor

struct DisabledCryptoDataProvider: CryptoDataProvider {
    func cryptocurrencyList(on _: Request) async throws -> [CryptoAssetResponse] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func quote(symbols _: String, on _: Request) async throws -> [CryptoQuoteResponse] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func quoteShort(symbol _: String, on _: Request) async throws -> [CryptoQuoteShortResponse] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func batchQuotes(short _: Bool, on _: Request) async throws -> [CryptoQuoteShortResponse] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func historicalLight(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> [CryptoHistoricalLightPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func historicalFull(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> [CryptoHistoricalFullPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func intraday1min(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> [CryptoHistoricalPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func intraday5min(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> [CryptoHistoricalPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func intraday1hour(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> [CryptoHistoricalPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func fetchCryptoNews(symbol _: String?, page _: Int?, limit _: Int?, from _: String?, to _: String?, on _: Request) async throws -> [FMPMarketNewsItem] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }
}
