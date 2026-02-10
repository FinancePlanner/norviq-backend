import Vapor
import Foundation

struct StatisticsDTO: Content {
    let generatedAt: String
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

extension StatisticsDTO {
    init(from model: StatisticsViewModel) {
        self.generatedAt = Self.formatDateTime(model.generatedAt)
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
                date: Self.formatDateOnly($0.date),
                pnl: $0.pnl,
                pnlPercent: $0.pnlPercent,
                isUpDay: $0.isUpDay
            )
        }
    }

    private static func formatDateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func formatDateTime(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
