import Foundation
import StockPlanShared

/// Everything the markets view needs, captured once per refresh. Coins are
/// ranked by market cap with stablecoins already removed; `changePct` is nil
/// until a timeframe is projected onto them.
struct CryptoMarketSnapshot: Codable, Sendable, Equatable {
    let source: String
    let attribution: String?
    /// ISO 8601.
    let asOf: String
    /// Whole fetched universe, stablecoins included.
    let totalMarketCap: Double?
    let btcDominancePct: Double?
    let coins: [CryptoMarketCoin]
}

/// Liquidity floor for the performer lists and the ATH board, so a thinly
/// traded micro-cap's +900% never tops the table. The full coin list (bubbles,
/// heatmap) is not filtered.
struct CryptoMarketsFilter: Sendable, Equatable {
    var minMarketCap: Double = 100_000_000
    var minVolume24h: Double = 1_000_000
    var listSize: Int = 10
}

/// Pure projection of a snapshot onto one timeframe. No I/O, so each request
/// is a cheap re-sort of the cached snapshot rather than a cache entry per
/// timeframe.
enum CryptoMarketsAssembler {
    static let recentAthWindow: TimeInterval = 30 * 86400
    static let sparklinePoints = 28

    static func assemble(
        snapshot: CryptoMarketSnapshot,
        timeframe: CryptoMarketsTimeframe,
        limit: Int,
        isStale: Bool,
        filter: CryptoMarketsFilter,
        now: Date
    ) -> CryptoMarketsResponse {
        let projected = snapshot.coins.map { $0.replacing(changePct: changePct($0, for: timeframe)) }
        let listed = Array(projected.prefix(max(0, limit)))

        let liquid = projected.filter {
            ($0.marketCap ?? 0) >= filter.minMarketCap && ($0.volume24h ?? 0) >= filter.minVolume24h
        }
        let ranked = liquid
            .filter { $0.changePct != nil }
            .sorted { ($0.changePct ?? 0) > ($1.changePct ?? 0) }

        // Every coin sits at or below its high, so for all-time "best" means
        // closest to the high rather than positive.
        let gainers: [CryptoMarketCoin]
        let losers: [CryptoMarketCoin]
        if timeframe == .allTime {
            gainers = Array(ranked.prefix(filter.listSize))
            losers = Array(ranked.reversed().prefix(filter.listSize))
        } else {
            gainers = Array(ranked.filter { ($0.changePct ?? 0) > 0 }.prefix(filter.listSize))
            losers = Array(ranked.reversed().filter { ($0.changePct ?? 0) < 0 }.prefix(filter.listSize))
        }

        let (mode, maxPct) = colorScale(for: timeframe)
        return CryptoMarketsResponse(
            timeframe: timeframe,
            supportedTimeframes: supportedTimeframes(in: snapshot.coins),
            source: snapshot.source,
            asOf: snapshot.asOf,
            isStale: isStale,
            colorMode: mode,
            colorScaleMaxPct: maxPct,
            attribution: snapshot.attribution,
            summary: summary(listed, snapshot: snapshot, timeframe: timeframe),
            coins: listed,
            gainers: gainers,
            losers: losers,
            athBoard: athBoard(liquid, listSize: filter.listSize, now: now)
        )
    }

    static func changePct(_ coin: CryptoMarketCoin, for timeframe: CryptoMarketsTimeframe) -> Double? {
        timeframe == .allTime ? coin.athChangePct : coin.returns.value(for: timeframe)
    }

    /// Shared by web and iOS so both colour a given move identically.
    static func colorScale(for timeframe: CryptoMarketsTimeframe) -> (mode: CryptoMarketsColorMode, maxPct: Double) {
        switch timeframe {
        case .oneDay: (.change, 5)
        case .oneWeek: (.change, 15)
        case .oneMonth: (.change, 30)
        case .yearToDate, .oneYear: (.change, 100)
        case .allTime: (.athDistance, 90)
        }
    }

    static func supportedTimeframes(in coins: [CryptoMarketCoin]) -> [CryptoMarketsTimeframe] {
        CryptoMarketsTimeframe.allCases.filter { timeframe in
            coins.contains { changePct($0, for: timeframe) != nil }
        }
    }

    /// Evenly spaced samples that always keep the first and last point.
    static func downsample(_ points: [Double], to count: Int) -> [Double] {
        guard count > 1, points.count > count else { return points }
        let step = Double(points.count - 1) / Double(count - 1)
        return (0 ..< count).map { points[Int((Double($0) * step).rounded())] }
    }

    private static func summary(
        _ coins: [CryptoMarketCoin],
        snapshot: CryptoMarketSnapshot,
        timeframe: CryptoMarketsTimeframe
    ) -> CryptoMarketsSummary {
        // Breadth is about direction; for all-time (every value ≤ 0) count
        // today's movers instead.
        let window: CryptoMarketsTimeframe = timeframe == .allTime ? .oneDay : timeframe
        let moves = coins.compactMap { changePct($0, for: window) }
        return CryptoMarketsSummary(
            totalMarketCap: snapshot.totalMarketCap,
            btcDominancePct: snapshot.btcDominancePct,
            advancers: moves.count(where: { $0 > 0 }),
            decliners: moves.count(where: { $0 < 0 })
        )
    }

    private static func athBoard(_ coins: [CryptoMarketCoin], listSize: Int, now: Date) -> CryptoAthBoard {
        let withAth = coins.filter { $0.athChangePct != nil }
        let byDistance = withAth.sorted { ($0.athChangePct ?? 0) > ($1.athChangePct ?? 0) }
        let recent = withAth
            .compactMap { coin -> (CryptoMarketCoin, Date)? in
                guard let date = coin.athDate.flatMap(parseISO8601),
                      now.timeIntervalSince(date) <= recentAthWindow else { return nil }
                return (coin, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        return CryptoAthBoard(
            recentAths: Array(recent.prefix(listSize)),
            nearAth: Array(byDistance.prefix(listSize)),
            deepestDrawdowns: Array(byDistance.reversed().prefix(listSize))
        )
    }

    /// CoinGecko sends fractional seconds (`2025-10-06T10:57:42.000Z`); other
    /// sources may not.
    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

extension CryptoMarketCoin {
    /// Copy with the per-request and per-refresh fields replaced. Omitted
    /// arguments keep the current value.
    func replacing(
        fmpSymbol: String?? = .none,
        sector: String? = nil,
        returns: CryptoTimeframeReturns? = nil,
        changePct: Double?? = .none
    ) -> CryptoMarketCoin {
        CryptoMarketCoin(
            id: id,
            symbol: symbol,
            fmpSymbol: fmpSymbol ?? self.fmpSymbol,
            name: name,
            imageUrl: imageUrl,
            rank: rank,
            sector: sector ?? self.sector,
            price: price,
            marketCap: marketCap,
            volume24h: volume24h,
            changePct: changePct ?? self.changePct,
            returns: returns ?? self.returns,
            ath: ath,
            athChangePct: athChangePct,
            athDate: athDate,
            atl: atl,
            atlChangePct: atlChangePct,
            atlDate: atlDate,
            sparkline7d: sparkline7d
        )
    }
}
