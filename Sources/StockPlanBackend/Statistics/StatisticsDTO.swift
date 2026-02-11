import Vapor
import Foundation

struct StatisticsDTO: Content {
    let generatedAt: String
    let importedStocks: ImportedStocksStatisticsDTO
    let watchlist: WatchlistStatisticsDTO
    let looklist: LooklistStatisticsDTO
    let market: MarketStatisticsDTO
}

struct ImportedStocksStatisticsDTO: Content {
    let totalPositions: Int
    let totalMarketValue: Double
    let totalCostBasis: Double
    let totalUnrealizedPnl: Double
    let totalRealizedPnl: Double
    let stockSummaries: [StockStatisticsSummaryDTO]
    let stockAllocations: [StockAllocationDTO]
    let sectorAllocations: [SectorAllocationDTO]
    let calendarPerformance: [CalendarPerformanceDTO]
}

typealias StatisticsResponse = StatisticsDTO

struct StockStatisticsSummaryDTO: Content {
    let symbol: String
    let marketValue: Double
    let weightPercent: Double
    let dailyChangePercent: Double?
    let unrealizedPnl: Double
}

struct StockAllocationDTO: Content {
    let symbol: String
    let value: Double
    let weightPercent: Double
}

struct SectorAllocationDTO: Content {
    let sector: String
    let value: Double
    let weightPercent: Double
}

struct CalendarPerformanceDTO: Content {
    let date: String
    let pnl: Double
    let pnlPercent: Double
    let isUpDay: Bool
}

struct WatchlistStatisticsDTO: Content {
    let totalSymbols: Int
    let symbolsWithNotes: Int
    let sectorAllocations: [SectorAllocationDTO]
    let topWatched: [WatchlistSymbolDTO]
}

struct WatchlistSymbolDTO: Content {
    let symbol: String
    let mentionCount: Int
}

struct LooklistStatisticsDTO: Content {
    let totalIdeas: Int
    let activeIdeas: Int
    let ideasWithTarget: Int
    let ideasByConviction: [LooklistConvictionDTO]
}

struct LooklistConvictionDTO: Content {
    let conviction: String
    let count: Int
}

struct MarketStatisticsDTO: Content {
    let benchmarkSymbol: String
    let benchmarkChange1D: Double?
    let benchmarkChange1W: Double?
    let benchmarkChange1M: Double?
    let benchmarkChangeYtd: Double?
    let heatmap: [MarketHeatmapDTO]
}

struct MarketHeatmapDTO: Content {
    let symbol: String
    let changePercent: Double
}

extension StatisticsDTO {
    init(from model: StatisticsViewModel) {
        self.generatedAt = Self.formatDateTime(model.generatedAt)
        self.importedStocks = ImportedStocksStatisticsDTO(from: model.importedStocks)
        self.watchlist = WatchlistStatisticsDTO(from: model.watchlist)
        self.looklist = LooklistStatisticsDTO(from: model.looklist)
        self.market = MarketStatisticsDTO(from: model.market)
    }

    static func formatDateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func formatDateTime(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension ImportedStocksStatisticsDTO {
    init(from model: ImportedStocksStatisticsView) {
        self.totalPositions = model.totalPositions
        self.totalMarketValue = model.totalMarketValue
        self.totalCostBasis = model.totalCostBasis
        self.totalUnrealizedPnl = model.totalUnrealizedPnl
        self.totalRealizedPnl = model.totalRealizedPnl
        self.stockSummaries = model.stockSummaries.map {
            StockStatisticsSummaryDTO(
                symbol: $0.symbol,
                marketValue: $0.marketValue,
                weightPercent: $0.weightPercent,
                dailyChangePercent: $0.dailyChangePercent,
                unrealizedPnl: $0.unrealizedPnl
            )
        }
        self.stockAllocations = model.stockAllocations.map {
            StockAllocationDTO(
                symbol: $0.symbol,
                value: $0.value,
                weightPercent: $0.weightPercent
            )
        }
        self.sectorAllocations = model.sectorAllocations.map {
            SectorAllocationDTO(
                sector: $0.sector,
                value: $0.value,
                weightPercent: $0.weightPercent
            )
        }
        self.calendarPerformance = model.calendarPerformance.map {
            CalendarPerformanceDTO(
                date: StatisticsDTO.formatDateOnly($0.date),
                pnl: $0.pnl,
                pnlPercent: $0.pnlPercent,
                isUpDay: $0.isUpDay
            )
        }
    }
}

private extension WatchlistStatisticsDTO {
    init(from model: WatchlistStatisticsView) {
        self.totalSymbols = model.totalSymbols
        self.symbolsWithNotes = model.symbolsWithNotes
        self.sectorAllocations = model.sectorAllocations.map {
            SectorAllocationDTO(
                sector: $0.sector,
                value: $0.value,
                weightPercent: $0.weightPercent
            )
        }
        self.topWatched = model.topWatched.map {
            WatchlistSymbolDTO(symbol: $0.symbol, mentionCount: $0.mentionCount)
        }
    }
}

private extension LooklistStatisticsDTO {
    init(from model: LooklistStatisticsView) {
        self.totalIdeas = model.totalIdeas
        self.activeIdeas = model.activeIdeas
        self.ideasWithTarget = model.ideasWithTarget
        self.ideasByConviction = model.ideasByConviction.map {
            LooklistConvictionDTO(conviction: $0.conviction, count: $0.count)
        }
    }
}

private extension MarketStatisticsDTO {
    init(from model: MarketStatisticsView) {
        self.benchmarkSymbol = model.benchmarkSymbol
        self.benchmarkChange1D = model.benchmarkChange1D
        self.benchmarkChange1W = model.benchmarkChange1W
        self.benchmarkChange1M = model.benchmarkChange1M
        self.benchmarkChangeYtd = model.benchmarkChangeYtd
        self.heatmap = model.heatmap.map {
            MarketHeatmapDTO(symbol: $0.symbol, changePercent: $0.changePercent)
        }
    }
}
