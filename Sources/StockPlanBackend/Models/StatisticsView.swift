import Foundation

struct StatisticsViewModel: Sendable {
    let generatedAt: Date
    let importedStocks: ImportedStocksStatisticsView
    let watchlist: WatchlistStatisticsView
    let looklist: LooklistStatisticsView
    let market: MarketStatisticsView
}

struct ImportedStocksStatisticsView: Sendable {
    let totalPositions: Int
    let totalMarketValue: Double
    let totalCostBasis: Double
    let totalUnrealizedPnl: Double
    let totalRealizedPnl: Double
    let stockSummaries: [StockStatisticsSummary]
    let stockAllocations: [StockAllocationPoint]
    let sectorAllocations: [SectorAllocationPoint]
    let calendarPerformance: [CalendarPerformancePoint]
}

struct WatchlistStatisticsView: Sendable {
    let totalSymbols: Int
    let symbolsWithNotes: Int
    let sectorAllocations: [SectorAllocationPoint]
    let topWatched: [WatchlistSymbolPoint]
}

struct LooklistStatisticsView: Sendable {
    let totalIdeas: Int
    let activeIdeas: Int
    let ideasWithTarget: Int
    let ideasByConviction: [LooklistConvictionPoint]
}

struct MarketStatisticsView: Sendable {
    let benchmarkSymbol: String
    let benchmarkChange1D: Double?
    let benchmarkChange1W: Double?
    let benchmarkChange1M: Double?
    let benchmarkChangeYtd: Double?
    let heatmap: [MarketHeatmapPoint]
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

struct WatchlistSymbolPoint: Sendable {
    let symbol: String
    let mentionCount: Int
}

struct LooklistConvictionPoint: Sendable {
    let conviction: String
    let count: Int
}

struct MarketHeatmapPoint: Sendable {
    let symbol: String
    let changePercent: Double
}
