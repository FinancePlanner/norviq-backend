import Foundation
import StockPlanShared
import Vapor

typealias StatisticsDTO = StockPlanShared.StatisticsDTO
typealias ImportedStocksStatisticsDTO = StockPlanShared.ImportedStocksStatisticsDTO
typealias StatisticsResponse = StockPlanShared.StatisticsResponse
typealias StockStatisticsSummaryDTO = StockPlanShared.StockStatisticsSummaryDTO
typealias StockAllocationDTO = StockPlanShared.StockAllocationDTO
typealias SectorAllocationDTO = StockPlanShared.SectorAllocationDTO
typealias CalendarPerformanceDTO = StockPlanShared.CalendarPerformanceDTO
typealias WatchlistStatisticsDTO = StockPlanShared.WatchlistStatisticsDTO
typealias WatchlistSymbolDTO = StockPlanShared.WatchlistSymbolDTO
typealias LooklistStatisticsDTO = StockPlanShared.LooklistStatisticsDTO
typealias LooklistConvictionDTO = StockPlanShared.LooklistConvictionDTO
typealias MarketStatisticsDTO = StockPlanShared.MarketStatisticsDTO
typealias MarketHeatmapDTO = StockPlanShared.MarketHeatmapDTO

extension StatisticsDTO: Content {}
extension ImportedStocksStatisticsDTO: Content {}
extension StockStatisticsSummaryDTO: Content {}
extension StockAllocationDTO: Content {}
extension SectorAllocationDTO: Content {}
extension CalendarPerformanceDTO: Content {}
extension WatchlistStatisticsDTO: Content {}
extension WatchlistSymbolDTO: Content {}
extension LooklistStatisticsDTO: Content {}
extension LooklistConvictionDTO: Content {}
extension MarketStatisticsDTO: Content {}
extension MarketHeatmapDTO: Content {}

extension StatisticsDTO {
    init(from model: StatisticsViewModel) {
        self.init(
            generatedAt: Self.formatDateTime(model.generatedAt),
            importedStocks: ImportedStocksStatisticsDTO(from: model.importedStocks),
            watchlist: WatchlistStatisticsDTO(from: model.watchlist),
            looklist: LooklistStatisticsDTO(from: model.looklist),
            market: MarketStatisticsDTO(from: model.market)
        )
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

extension ImportedStocksStatisticsDTO {
    fileprivate init(from model: ImportedStocksStatisticsView) {
        self.init(
            totalPositions: model.totalPositions,
            totalMarketValue: model.totalMarketValue,
            totalCostBasis: model.totalCostBasis,
            totalUnrealizedPnl: model.totalUnrealizedPnl,
            totalRealizedPnl: model.totalRealizedPnl,
            stockSummaries: model.stockSummaries.map {
                StockStatisticsSummaryDTO(
                    symbol: $0.symbol,
                    marketValue: $0.marketValue,
                    weightPercent: $0.weightPercent,
                    dailyChangePercent: $0.dailyChangePercent,
                    weeklyChangePercent: $0.weeklyChangePercent,
                    monthlyChangePercent: $0.monthlyChangePercent,
                    unrealizedPnl: $0.unrealizedPnl
                )
            },
            stockAllocations: model.stockAllocations.map {
                StockAllocationDTO(
                    symbol: $0.symbol,
                    value: $0.value,
                    weightPercent: $0.weightPercent
                )
            },
            sectorAllocations: model.sectorAllocations.map {
                SectorAllocationDTO(
                    sector: $0.sector,
                    value: $0.value,
                    weightPercent: $0.weightPercent
                )
            },
            calendarPerformance: model.calendarPerformance.map {
                CalendarPerformanceDTO(
                    date: StatisticsDTO.formatDateOnly($0.date),
                    pnl: $0.pnl,
                    pnlPercent: $0.pnlPercent,
                    isUpDay: $0.isUpDay
                )
            }
        )
    }
}

extension WatchlistStatisticsDTO {
    fileprivate init(from model: WatchlistStatisticsView) {
        self.init(
            totalSymbols: model.totalSymbols,
            symbolsWithNotes: model.symbolsWithNotes,
            sectorAllocations: model.sectorAllocations.map {
                SectorAllocationDTO(
                    sector: $0.sector,
                    value: $0.value,
                    weightPercent: $0.weightPercent
                )
            },
            topWatched: model.topWatched.map {
                WatchlistSymbolDTO(symbol: $0.symbol, mentionCount: $0.mentionCount)
            }
        )
    }
}

extension LooklistStatisticsDTO {
    fileprivate init(from model: LooklistStatisticsView) {
        self.init(
            totalIdeas: model.totalIdeas,
            activeIdeas: model.activeIdeas,
            ideasWithTarget: model.ideasWithTarget,
            ideasByConviction: model.ideasByConviction.map {
                LooklistConvictionDTO(conviction: $0.conviction, count: $0.count)
            }
        )
    }
}

extension MarketStatisticsDTO {
    fileprivate init(from model: MarketStatisticsView) {
        self.init(
            benchmarkSymbol: model.benchmarkSymbol,
            benchmarkChange1D: model.benchmarkChange1D,
            benchmarkChange1W: model.benchmarkChange1W,
            benchmarkChange1M: model.benchmarkChange1M,
            benchmarkChangeYtd: model.benchmarkChangeYtd,
            heatmap: model.heatmap.map {
                MarketHeatmapDTO(symbol: $0.symbol, changePercent: $0.changePercent)
            }
        )
    }
}
