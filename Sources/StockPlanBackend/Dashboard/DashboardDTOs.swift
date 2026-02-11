import Vapor

struct DashboardResponse: Content {
    let generatedAt: String
    let portfolio: DashboardPortfolioSummary
    let topHoldings: [DashboardHolding]
    let recentNews: [DashboardNewsItem]
}

struct DashboardPortfolioSummary: Content {
    let totalPositions: Int
    let totalCostBasis: Double
    let totalMarketValue: Double
    let totalUnrealizedPnl: Double
    let watchlistCount: Int
    let researchCount: Int
    let targetsCount: Int
}

struct DashboardHolding: Content {
    let symbol: String
    let marketValue: Double
    let weightPercent: Double
}

struct DashboardNewsItem: Content {
    let id: String
    let symbol: String
    let headline: String
    let source: String?
    let publishedAt: String
}
