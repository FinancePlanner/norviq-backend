import Foundation

struct StatisticsViewModel: Sendable {
    let generatedAt: Date
    let totalMarketValue: Double
    let totalCostBasis: Double
    let totalUnrealizedPnl: Double
    let totalRealizedPnl: Double
    let stockSummaries: [StockStatisticsSummary]
    let stockAllocations: [StockAllocationPoint]
    let sectorAllocations: [SectorAllocationPoint]
    let calendarPerformance: [CalendarPerformancePoint]
}

struct StockStatisticsSummary: Sendable {
    let symbol: String
    let marketValue: Double
    let weightPercent: Double
    let dailyChangePercent: Double?
    let unrealizedPnl: Double
}

struct StockAllocationPoint: Sendable {
    let symbol: String
    let value: Double
    let weightPercent: Double
}

struct SectorAllocationPoint: Sendable {
    let sector: String
    let value: Double
    let weightPercent: Double
}

struct CalendarPerformancePoint: Sendable {
    let date: Date
    let pnl: Double
    let pnlPercent: Double
    let isUpDay: Bool
}
