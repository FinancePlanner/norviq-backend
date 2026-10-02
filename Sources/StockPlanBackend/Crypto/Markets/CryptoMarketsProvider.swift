import Foundation
import StockPlanShared
import Vapor

/// Source of the ranked crypto universe (prices, multi-window returns, ATH).
/// Named for the role; implementations are named for their wire format.
protocol CryptoMarketsProvider: Sendable {
    var name: String { get }
    /// Credit line the source's terms require clients to display.
    var attribution: String? { get }
    /// Top coins by market cap. `fmpSymbol` is nil and `sector` is "Other";
    /// the service fills both in.
    func fetchUniverse(limit: Int, on req: Request) async throws -> [CryptoMarketCoin]
    /// Provider ids to keep out of every list (stablecoins).
    func fetchExcludedIds(on req: Request) async throws -> Set<String>
}

/// Reference data that comes from FMP rather than the markets provider: which
/// coins FMP carries (detail pages chart FMP history) and the year-start price
/// used for YTD.
protocol CryptoReferenceDataSource: Sendable {
    /// FMP symbols such as `BTCUSD`.
    func knownSymbols(on req: Request) async throws -> Set<String>
    /// Last close before 1 January of `year`, or nil when FMP has no history
    /// for that window.
    func yearStartPrice(symbol: String, year: Int, on req: Request) async throws -> Double?
}

struct FMPCryptoReferenceDataSource: CryptoReferenceDataSource {
    let provider: any CryptoDataProvider

    func knownSymbols(on req: Request) async throws -> Set<String> {
        try await Set(provider.cryptocurrencyList(on: req).map { $0.symbol.uppercased() })
    }

    func yearStartPrice(symbol: String, year: Int, on req: Request) async throws -> Double? {
        // A few days either side of New Year so a missing print on the 31st
        // (thin coverage) still finds the nearest close.
        let points = try await provider.historicalLight(
            symbol: symbol, from: "\(year - 1)-12-26", to: "\(year)-01-05", on: req
        )
        let boundary = "\(year)-01-01"
        let sorted = points.sorted { $0.date < $1.date }
        let close = sorted.last(where: { $0.date < boundary }) ?? sorted.first
        return close.map(\.price).flatMap { $0 > 0 ? $0 : nil }
    }
}

// MARK: - CoinGecko

struct CoinGeckoV3CryptoMarketsProvider: CryptoMarketsProvider {
    /// `public` needs no key but is heavily rate limited; `demo` and `pro` keys
    /// use different hosts and headers.
    enum Plan: String {
        case `public`
        case demo
        case pro
    }

    let apiKey: String?
    let plan: Plan

    var name: String {
        "coingecko"
    }

    var attribution: String? {
        "Data provided by CoinGecko"
    }

    private var baseURL: String {
        plan == .pro ? "https://pro-api.coingecko.com/api/v3" : "https://api.coingecko.com/api/v3"
    }

    init(apiKey: String?, plan: Plan) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = trimmed?.isEmpty == false ? trimmed : nil
        // A plan that needs a key without one degrades to the public API.
        self.plan = self.apiKey == nil ? .public : plan
    }

    func fetchUniverse(limit: Int, on req: Request) async throws -> [CryptoMarketCoin] {
        let items: [CoinGeckoMarketItem] = try await fetch(
            "/coins/markets",
            query: [
                ("vs_currency", "usd"),
                ("order", "market_cap_desc"),
                ("per_page", String(min(max(limit, 1), 250))),
                ("page", "1"),
                ("sparkline", "true"),
                ("price_change_percentage", "24h,7d,30d,1y"),
            ],
            on: req
        )
        return items.compactMap(\.marketCoin)
    }

    func fetchExcludedIds(on req: Request) async throws -> Set<String> {
        // `/coins/markets` already leaves out wrapped and liquid-staking
        // derivatives, so stablecoins are the only category to drop.
        let items: [CoinGeckoMarketItem] = try await fetch(
            "/coins/markets",
            query: [("vs_currency", "usd"), ("category", "stablecoins"), ("per_page", "250"), ("page", "1")],
            on: req
        )
        return Set(items.map(\.id))
    }

    private func fetch<Body: Decodable>(_ path: String, query: [(String, String)], on req: Request) async throws -> Body {
        var components = URLComponents(string: baseURL + path)
        components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else {
            throw Abort(.internalServerError, reason: "Invalid CoinGecko URL.")
        }
        let response = try await req.client.get(URI(string: url.absoluteString)) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            // CoinGecko's edge answers 403 to requests with no User-Agent,
            // which is what the Vapor client sends by default.
            clientRequest.headers.replaceOrAdd(name: .userAgent, value: "Norviq/1.0 (+https://norviq.org)")
            if let apiKey {
                clientRequest.headers.replaceOrAdd(
                    name: plan == .pro ? "x-cg-pro-api-key" : "x-cg-demo-api-key",
                    value: apiKey
                )
            }
            clientRequest.timeout = .seconds(30)
        }
        switch response.status {
        case .ok:
            do {
                return try response.content.decode(Body.self)
            } catch {
                throw Abort(.badGateway, reason: "Failed to decode CoinGecko response for \(path).")
            }
        case .tooManyRequests:
            // The refresh job just waits for its next tick; retrying inline
            // only burns the monthly quota.
            req.logger.warning("coingecko rate limited path=\(path) retry_after=\(response.headers.first(name: "Retry-After") ?? "-")")
            throw Abort(.tooManyRequests, reason: "Crypto market data is rate limited.")
        default:
            req.logger.error("coingecko request failed path=\(path) status=\(response.status.code)")
            throw Abort(.badGateway, reason: "Crypto market data isn’t available right now.")
        }
    }
}

/// `/coins/markets` item. Every field but the id is optional: CoinGecko nulls
/// whatever it lacks (a new listing has no 1y change).
struct CoinGeckoMarketItem: Decodable, Sendable {
    let id: String
    let symbol: String?
    let name: String?
    let image: String?
    let marketCapRank: Int?
    let currentPrice: Double?
    let marketCap: Double?
    let totalVolume: Double?
    let priceChangePercentage24h: Double?
    let priceChangePercentage24hInCurrency: Double?
    let priceChangePercentage7dInCurrency: Double?
    let priceChangePercentage30dInCurrency: Double?
    let priceChangePercentage1yInCurrency: Double?
    let ath: Double?
    let athChangePercentage: Double?
    let athDate: String?
    let atl: Double?
    let atlChangePercentage: Double?
    let atlDate: String?
    let sparklineIn7d: Sparkline?

    struct Sparkline: Decodable, Sendable {
        let price: [Double]?
    }

    enum CodingKeys: String, CodingKey {
        case id, symbol, name, image, ath, atl
        case marketCapRank = "market_cap_rank"
        case currentPrice = "current_price"
        case marketCap = "market_cap"
        case totalVolume = "total_volume"
        case priceChangePercentage24h = "price_change_percentage_24h"
        case priceChangePercentage24hInCurrency = "price_change_percentage_24h_in_currency"
        case priceChangePercentage7dInCurrency = "price_change_percentage_7d_in_currency"
        case priceChangePercentage30dInCurrency = "price_change_percentage_30d_in_currency"
        case priceChangePercentage1yInCurrency = "price_change_percentage_1y_in_currency"
        case athChangePercentage = "ath_change_percentage"
        case athDate = "ath_date"
        case atlChangePercentage = "atl_change_percentage"
        case atlDate = "atl_date"
        case sparklineIn7d = "sparkline_in_7d"
    }

    /// Nil when the item has no price or ticker, which makes it unusable.
    var marketCoin: CryptoMarketCoin? {
        guard let currentPrice, let symbol, !symbol.isEmpty else { return nil }
        return CryptoMarketCoin(
            id: id,
            symbol: symbol.uppercased(),
            name: name ?? symbol.uppercased(),
            imageUrl: image,
            rank: marketCapRank,
            sector: CryptoSectorMap.otherSector,
            price: currentPrice,
            marketCap: marketCap,
            volume24h: totalVolume,
            returns: CryptoTimeframeReturns(
                oneDay: priceChangePercentage24hInCurrency ?? priceChangePercentage24h,
                oneWeek: priceChangePercentage7dInCurrency,
                oneMonth: priceChangePercentage30dInCurrency,
                oneYear: priceChangePercentage1yInCurrency
            ),
            ath: ath,
            athChangePct: athChangePercentage,
            athDate: athDate,
            atl: atl,
            atlChangePct: atlChangePercentage,
            atlDate: atlDate,
            sparkline7d: CryptoMarketsAssembler.downsample(
                sparklineIn7d?.price ?? [], to: CryptoMarketsAssembler.sparklinePoints
            )
        )
    }
}
