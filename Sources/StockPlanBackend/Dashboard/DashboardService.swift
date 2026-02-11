import Vapor
import Fluent
import Foundation

protocol DashboardService: Sendable {
    func dashboard(userId: UUID, on db: any Database) async throws -> DashboardResponse
}

struct DefaultDashboardService: DashboardService {
    let repo: any DashboardRepository

    func dashboard(userId: UUID, on db: any Database) async throws -> DashboardResponse {
        let snapshot = try await repo.snapshot(userId: userId, on: db)

        return DashboardResponse(
            generatedAt: formatISODateTime(snapshot.generatedAt),
            portfolio: DashboardPortfolioSummary(
                totalPositions: snapshot.portfolio.totalPositions,
                totalCostBasis: snapshot.portfolio.totalCostBasis,
                totalMarketValue: snapshot.portfolio.totalMarketValue,
                totalUnrealizedPnl: snapshot.portfolio.totalUnrealizedPnl,
                watchlistCount: snapshot.portfolio.watchlistCount,
                researchCount: snapshot.portfolio.researchCount,
                targetsCount: snapshot.portfolio.targetsCount
            ),
            topHoldings: snapshot.topHoldings.map {
                DashboardHolding(
                    symbol: $0.symbol,
                    marketValue: $0.marketValue,
                    weightPercent: $0.weightPercent
                )
            },
            recentNews: snapshot.recentNews.map {
                DashboardNewsItem(
                    id: $0.id.uuidString,
                    symbol: $0.symbol,
                    headline: $0.headline,
                    source: $0.source,
                    publishedAt: formatISODateTime($0.publishedAt)
                )
            }
        )
    }
}

private extension DefaultDashboardService {
    func formatISODateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
