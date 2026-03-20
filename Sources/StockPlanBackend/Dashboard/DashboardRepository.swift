import Fluent
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

        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .all()
        let watchlistCount = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$status != "archived")
            .count()
        let researchCount = try await ResearchNote.query(on: db)
            .filter(\.$userId == userId)
            .count()
        let targetsCount = try await Target.query(on: db)
            .filter(\.$userId == userId)
            .count()

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

        let recentNews = try await NewsItem.query(on: db)
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
    func loadLatestQuotes(symbols: [String], on db: any Database) async throws -> [String: QuoteCache] {
        guard !symbols.isEmpty else { return [:] }
        let query = QuoteCache.query(on: db)
            .sort(\.$asOf, .descending)

        query.group(.or) { group in
            for symbol in symbols {
                group.filter(\.$symbol == symbol)
            }
        }

        let rows = try await query.all()
        var result: [String: QuoteCache] = [:]
        for row in rows {
            let symbol = normalizeSymbol(row.symbol)
            if result[symbol] == nil {
                result[symbol] = row
            }
        }
        return result
    }

    func normalizeSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
