import Fluent
import FluentSQL
import Foundation

struct DashboardSnapshotModel: Sendable {
    struct Portfolio: Sendable {
        let totalPositions: Int
        let totalCostBasis: Double
        let totalMarketValue: Double
        let totalUnrealizedPnl: Double
        let watchlistCount: Int
        let researchCount: Int
        let targetsCount: Int
    }

    struct Holding: Sendable {
        let symbol: String
        let marketValue: Double
        let weightPercent: Double
    }

    struct News: Sendable {
        let id: UUID
        let symbol: String
        let headline: String
        let source: String?
        let publishedAt: Date
    }

    let generatedAt: Date
    let portfolio: Portfolio
    let topHoldings: [Holding]
    let recentNews: [News]
}

protocol DashboardRepository: Sendable {
    func snapshot(userId: UUID, on db: any Database) async throws -> DashboardSnapshotModel
}

struct DatabaseDashboardRepository: DashboardRepository {
    func snapshot(userId: UUID, on db: any Database) async throws -> DashboardSnapshotModel {
        let generatedAt = Date()

        async let stocksTask: [Stock] = Stock.query(on: db)
            .filter(\.$userId == userId)
            .all()
        async let watchlistCountTask: Int = WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$status != "archived")
            .count()
        async let researchCountTask: Int = ResearchNote.query(on: db)
            .filter(\.$userId == userId)
            .count()
        async let targetsCountTask: Int = Target.query(on: db)
            .filter(\.$userId == userId)
            .count()
        async let recentNewsTask: [DashboardSnapshotModel.News] = loadRecentNews(userId: userId, on: db)

        let stocks = try await stocksTask
        let watchlistCount = try await watchlistCountTask
        let researchCount = try await researchCountTask
        let targetsCount = try await targetsCountTask

        let symbols = Array(Set(stocks.map { normalizeSymbol($0.symbol) }))
        let latestQuotes = try await loadLatestQuotes(symbols: symbols, on: db)

        let rows = stocks.map { stock in
            let symbol = normalizeSymbol(stock.symbol)
            let price = latestQuotes[symbol]?.price ?? stock.buyPrice
            let costBasis = stock.shares * stock.buyPrice
            let marketValue = stock.shares * price
            return (symbol: symbol, costBasis: costBasis, marketValue: marketValue)
        }

        let totalCostBasis = rows.reduce(0.0) { $0 + $1.costBasis }
        let totalMarketValue = rows.reduce(0.0) { $0 + $1.marketValue }
        let totalUnrealizedPnl = totalMarketValue - totalCostBasis

        let topHoldings = rows
            .sorted { $0.marketValue > $1.marketValue }
            .prefix(5)
            .map { row in
                let weight = totalMarketValue > 0 ? (row.marketValue / totalMarketValue) * 100 : 0
                return DashboardSnapshotModel.Holding(
                    symbol: row.symbol,
                    marketValue: row.marketValue,
                    weightPercent: weight
                )
            }

        let recentNews = try await recentNewsTask

        return DashboardSnapshotModel(
            generatedAt: generatedAt,
            portfolio: .init(
                totalPositions: stocks.count,
                totalCostBasis: totalCostBasis,
                totalMarketValue: totalMarketValue,
                totalUnrealizedPnl: totalUnrealizedPnl,
                watchlistCount: watchlistCount,
                researchCount: researchCount,
                targetsCount: targetsCount
            ),
            topHoldings: topHoldings,
            recentNews: recentNews
        )
    }
}

private extension DatabaseDashboardRepository {
    func loadRecentNews(userId: UUID, on db: any Database) async throws -> [DashboardSnapshotModel.News] {
        try await NewsItem.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$publishedAt, .descending)
            .limit(5)
            .all()
            .compactMap { item -> DashboardSnapshotModel.News? in
                guard let id = item.id else { return nil }
                return .init(
                    id: id,
                    symbol: item.symbol,
                    headline: item.headline,
                    source: item.source,
                    publishedAt: item.publishedAt
                )
            }
    }

    struct LatestQuoteSnapshot: Sendable {
        let symbol: String
        let currency: String
        let price: Double
    }

    func loadLatestQuotes(symbols rawSymbols: [String], on db: any Database) async throws -> [String: LatestQuoteSnapshot] {
        let symbols = Array(Set(rawSymbols.map(normalizeSymbol))).sorted()
        guard !symbols.isEmpty else { return [:] }

        if let sql = db as? any SQLDatabase {
            // Use SQL-level "latest per symbol" to avoid loading stale rows and deduping in memory.
            let rows = try await sql.raw(
                """
                SELECT DISTINCT ON (symbol)
                    symbol,
                    currency,
                    price
                FROM quote_cache
                WHERE symbol = ANY(\(bind: symbols))
                ORDER BY symbol, as_of DESC
                """
            ).all()

            var result: [String: LatestQuoteSnapshot] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                guard
                    let symbol = try? row.decode(column: "symbol", as: String.self),
                    let currency = try? row.decode(column: "currency", as: String.self),
                    let price = try? row.decode(column: "price", as: Double.self)
                else {
                    continue
                }

                let normalized = normalizeSymbol(symbol)
                result[normalized] = LatestQuoteSnapshot(
                    symbol: normalized,
                    currency: currency,
                    price: price
                )
            }

            if !result.isEmpty {
                return result
            }
        }

        let rows = try await QuoteCache.query(on: db)
            .filter(\.$symbol ~~ symbols)
            .sort(\.$symbol, .ascending)
            .sort(\.$asOf, .descending)
            .all()

        var result: [String: LatestQuoteSnapshot] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let symbol = normalizeSymbol(row.symbol)
            if result[symbol] == nil {
                result[symbol] = LatestQuoteSnapshot(
                    symbol: symbol,
                    currency: row.currency,
                    price: row.price
                )
            }
        }
        return result
    }

    func normalizeSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
