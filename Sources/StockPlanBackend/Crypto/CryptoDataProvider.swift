import Foundation
import Vapor

protocol CryptoDataProvider: Sendable {
    func cryptocurrencyList(on req: Request) async throws -> [CryptoAssetResponse]
    func quote(symbols: String, on req: Request) async throws -> [CryptoQuoteResponse]
    func quoteShort(symbol: String, on req: Request) async throws -> [CryptoQuoteShortResponse]
    func batchQuotes(short: Bool, on req: Request) async throws -> [CryptoQuoteShortResponse]
    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalLightPoint]
    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalFullPoint]
    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
    func fetchCryptoNews(symbol: String?, page: Int?, limit: Int?, from: String?, to: String?, on req: Request) async throws -> [FMPMarketNewsItem]
}
