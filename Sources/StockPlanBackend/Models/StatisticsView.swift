import Foundation

struct StatisticsViewModel {
    let generatedAt: Date
    let importedStocks: ImportedStocksStatisticsView
    let watchlist: WatchlistStatisticsView
    let looklist: LooklistStatisticsView
    let market: MarketStatisticsView
}

struct ImportedStocksStatisticsView {
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

struct WatchlistStatisticsView {
    let totalSymbols: Int
    let symbolsWithNotes: Int
    let sectorAllocations: [SectorAllocationPoint]
    let topWatched: [WatchlistSymbolPoint]
}

struct LooklistStatisticsView {
    let totalIdeas: Int
    let activeIdeas: Int
    let ideasWithTarget: Int
    let ideasByConviction: [LooklistConvictionPoint]
}

struct MarketStatisticsView {
    let benchmarkSymbol: String
    let benchmarkChange1D: Double?
    let benchmarkChange1W: Double?
    let benchmarkChange1M: Double?
    let benchmarkChangeYtd: Double?
    let heatmap: [MarketHeatmapPoint]
}

struct StockStatisticsSummary {
    let symbol: String
    let marketValue: Double
    let weightPercent: Double
    let dailyChangePercent: Double?
    let weeklyChangePercent: Double?
    let monthlyChangePercent: Double?
    let unrealizedPnl: Double
}

struct StockAllocationPoint {
    let symbol: String
    let value: Double
    let weightPercent: Double
}

struct SectorAllocationPoint {
    let sector: String
    let value: Double
    let weightPercent: Double
}

struct CalendarPerformancePoint {
    let date: Date
    let pnl: Double
    let pnlPercent: Double
    let isUpDay: Bool
}

struct WatchlistSymbolPoint {
    let symbol: String
    let mentionCount: Int
}

struct LooklistConvictionPoint {
    let conviction: String
    let count: Int
}

struct MarketHeatmapPoint {
    let symbol: String
    let changePercent: Double
}
