import Foundation
import Vapor

struct MockCryptoDataProvider: CryptoDataProvider {
    func cryptocurrencyList(on req: Request) async throws -> [CryptoAssetResponse] {
        [
            CryptoAssetResponse(
                symbol: "BTCUSD",
                name: "Bitcoin",
                exchange: "CRYPTO",
                icoDate: "2009-01-03",
                circulatingSupply: 19000000,
                totalSupply: 21000000
            ),
            CryptoAssetResponse(
                symbol: "ETHUSD",
                name: "Ethereum",
                exchange: "CRYPTO",
                icoDate: "2015-07-30",
                circulatingSupply: 120000000,
                totalSupply: nil
            ),
            CryptoAssetResponse(
                symbol: "SOLUSD",
                name: "Solana",
                exchange: "CRYPTO",
                icoDate: "2020-03-16",
                circulatingSupply: 400000000,
                totalSupply: nil
            )
        ]
    }

    func quote(symbols: String, on req: Request) async throws -> [CryptoQuoteResponse] {
        [
            CryptoQuoteResponse(
                symbol: "BTCUSD",
                name: "Bitcoin",
                price: 118741.16,
                changePercentage: 1.25,
                change: 1450.50,
                volume: 75302985728,
                marketCap: 2344693699320,
                timestamp: Int(Date().timeIntervalSince1970)
            )
        ]
    }

    func quoteShort(symbol: String, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        [
            CryptoQuoteShortResponse(
                symbol: symbol.uppercased(),
                price: 118741.16,
                change: -37.93,
                volume: 75302985728
            )
        ]
    }

    func batchQuotes(short: Bool, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        [
            CryptoQuoteShortResponse(symbol: "BTCUSD", price: 118741.16, change: -37.93, volume: 75302985728),
            CryptoQuoteShortResponse(symbol: "ETHUSD", price: 4250.80, change: -36.20, volume: 25302985728)
        ]
    }

    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalLightPoint] {
        [
            CryptoHistoricalLightPoint(symbol: symbol.uppercased(), date: "2025-07-24", price: 118741.16, volume: 75302985728)
        ]
    }

    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalFullPoint] {
        [
            CryptoHistoricalFullPoint(
                symbol: symbol.uppercased(),
                date: "2025-07-24",
                open: 118779.09,
                high: 119535.45,
                low: 117435.22,
                close: 118741.16,
                volume: 75302985728,
                change: -37.93,
                changePercent: -0.03193323,
                vwap: 118570.61
            )
        ]
    }

    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        mockIntraday()
    }

    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        mockIntraday()
    }

    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        mockIntraday()
    }

    func fetchCryptoNews(symbol: String?, page: Int?, limit: Int?, from: String?, to: String?, on req: Request) async throws -> [FMPMarketNewsItem] {
        let allNews = [
            FMPMarketNewsItem(
                symbol: "BTCUSD",
                publishedDate: "2026-04-04 12:00:00",
                title: "Bitcoin Surges Past $118k as Institutional Adoption Grows",
                image: "https://example.com/btc.jpg",
                site: "CryptoNews",
                publisher: "CryptoNews",
                text: "The leading cryptocurrency continues its bull run as more companies add it to their balance sheet.",
                url: "https://example.com/1"
            ),
            FMPMarketNewsItem(
                symbol: "ETHUSD",
                publishedDate: "2026-04-04 11:30:00",
                title: "Ethereum Upgrade Successfully Completed on Testnet",
                image: "https://example.com/eth.jpg",
                site: "TheBlock",
                publisher: "TheBlock",
                text: "The upcoming hard fork aims to improve scalability and reduce transaction fees.",
                url: "https://example.com/2"
            )
        ]

        if let symbol {
            return allNews.filter { $0.symbol?.uppercased() == symbol.uppercased() }
        }
        return allNews
    }

    private func mockIntraday() -> [CryptoHistoricalPoint] {
        [
            CryptoHistoricalPoint(date: "2025-07-24 12:00:00", open: 118779.09, low: 117435.22, high: 119535.45, close: 118741.16, volume: 75302985728)
        ]
    }
}
