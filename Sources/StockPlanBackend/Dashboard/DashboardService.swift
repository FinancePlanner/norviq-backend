import Vapor
import Fluent
import Foundation

protocol DashboardService: Sendable {
    func dashboard(userId: UUID, on db: any Database) async throws -> DashboardResponse
}

struct DefaultDashboardService: DashboardService {
    let repo: any DashboardRepository
    let statisticsRepo: any StatisticsRepository

    func dashboard(userId: UUID, on db: any Database) async throws -> DashboardResponse {
        let overview = try await statisticsRepo.overviewStatistics(
            userId: userId,
            options: StatisticsQueryOptions(
                period: .oneMonth,
                top: 5,
                benchmarkSymbol: "SPY",
                asOfDate: nil
            ),
            on: db
        )

        let summaries = overview.importedStocks.stockSummaries
        let totalValue = overview.importedStocks.totalMarketValue
        let dailyChange = round2(summaries.reduce(0.0) { $0 + absoluteDailyChange(for: $1) })
        let previousTotal = totalValue - dailyChange
        let dailyChangePercent = previousTotal == 0 ? 0 : round2((dailyChange / previousTotal) * 100)

        return DashboardResponse(
            totalValue: totalValue,
            dailyChange: dailyChange,
            dailyChangePercent: dailyChangePercent,
            topPerformers: summaries
                .sorted(by: descendingPerformerOrder)
                .prefix(5)
                .map(makePerformer),
            bottomPerformers: summaries
                .sorted(by: ascendingPerformerOrder)
                .prefix(5)
                .map(makePerformer),
            sectorAllocation: overview.importedStocks.sectorAllocations.map {
                DashboardAllocationDTO(
                    sector: $0.sector,
                    value: $0.value,
                    percent: $0.weightPercent
                )
            }
        )
    }
}

private extension DefaultDashboardService {
    func makePerformer(_ summary: StockStatisticsSummary) -> DashboardPerformerDTO {
        DashboardPerformerDTO(
            symbol: summary.symbol,
            change: absoluteDailyChange(for: summary),
            changePercent: round2(summary.dailyChangePercent ?? 0)
        )
    }

    func absoluteDailyChange(for summary: StockStatisticsSummary) -> Double {
        let percent = summary.dailyChangePercent ?? 0
        let ratio = 1 + (percent / 100)
        guard ratio != 0 else { return 0 }
        let previousValue = summary.marketValue / ratio
        return round2(summary.marketValue - previousValue)
    }

    func descendingPerformerOrder(_ lhs: StockStatisticsSummary, _ rhs: StockStatisticsSummary) -> Bool {
        let lhsPercent = lhs.dailyChangePercent ?? 0
        let rhsPercent = rhs.dailyChangePercent ?? 0
        if lhsPercent == rhsPercent {
            return lhs.symbol < rhs.symbol
        }
        return lhsPercent > rhsPercent
    }

    func ascendingPerformerOrder(_ lhs: StockStatisticsSummary, _ rhs: StockStatisticsSummary) -> Bool {
        let lhsPercent = lhs.dailyChangePercent ?? 0
        let rhsPercent = rhs.dailyChangePercent ?? 0
        if lhsPercent == rhsPercent {
            return lhs.symbol < rhs.symbol
        }
        return lhsPercent < rhsPercent
    }

    func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
