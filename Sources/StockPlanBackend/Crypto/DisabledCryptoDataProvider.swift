import Foundation
import Vapor

struct DisabledCryptoDataProvider: CryptoDataProvider {
    func cryptocurrencyList(on req: Request) async throws -> [CryptoAssetResponse] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func quote(symbol: String, on req: Request) async throws -> [CryptoQuoteResponse] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func quoteShort(symbol: String, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func batchQuotes(short: Bool, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalLightPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalFullPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }

    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        throw Abort(.serviceUnavailable, reason: "Crypto market data is not configured.")
    }
}
