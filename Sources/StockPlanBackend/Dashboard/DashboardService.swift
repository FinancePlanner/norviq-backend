import Vapor
import Fluent
import StockPlanShared
import Foundation

protocol DashboardService: Sendable {
    func dashboard(userId: UUID, req: Request, on db: any Database) async throws -> DashboardResponse
    func insights(userId: UUID, req: Request, on db: any Database) async throws -> DashboardInsightsResponse
}

struct DefaultDashboardService: DashboardService {
    let repo: any DashboardRepository
    let statisticsRepo: any StatisticsRepository

    func dashboard(userId: UUID, req: Request, on db: any Database) async throws -> DashboardResponse {
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

    func insights(userId: UUID, req: Request, on db: any Database) async throws -> DashboardInsightsResponse {
        // Cash Buffer
        let accounts = try await Account.query(on: db).filter(\.$userId == userId).all()
        let accountIds = Set(accounts.compactMap { $0.id })
        var cashBuffer: Double = 0
        if !accountIds.isEmpty {
            let balances = try await CashBalance.query(on: db).filter(\.$accountId ~~ accountIds).all()
            cashBuffer = balances.reduce(0) { $0 + $1.balance }
        }

        // Watchlist Count
        let watchlistCount = try await WatchlistItem.query(on: db).filter(\.$userId == userId).count()

        // Expenses logic
        let monthlyReports = try await req.expensesService.getMonthlyReports(userId: userId, from: nil, to: nil, on: db)
        
        var budgetStreak = 0
        for report in monthlyReports.reversed() { // newest first, because getMonthlyReports is sorted asc
            if report.actual <= report.planned && report.planned > 0 {
                budgetStreak += 1
            } else {
                break
            }
        }
        
        var savingsRate: Double = 0
        if let lastReport = monthlyReports.last, lastReport.salary > 0 {
            savingsRate = (lastReport.salary - lastReport.actual) / lastReport.salary * 100
            savingsRate = max(0, savingsRate)
        }

        let financialHealth = makeFinancialHealth(
            savingsRate: savingsRate,
            budgetStreak: budgetStreak,
            cashBuffer: cashBuffer,
            latestMonthlyActualExpenses: monthlyReports.last?.actual
        )
        
        return DashboardInsightsResponse(
            savingsRate: round2(savingsRate),
            budgetStreak: budgetStreak,
            watchlistCount: watchlistCount,
            cashBuffer: round2(cashBuffer),
            financialHealth: financialHealth
        )
    }
}

private extension DefaultDashboardService {
    func makeFinancialHealth(
        savingsRate: Double,
        budgetStreak: Int,
        cashBuffer: Double,
        latestMonthlyActualExpenses: Double?
    ) -> DashboardFinancialHealthDTO {
        let clampedSavingsRate = max(0, savingsRate)
        let normalizedSavingsRate = min(clampedSavingsRate / 30.0, 1.0)
        let savingsComponent = normalizedSavingsRate * 40.0

        let clampedBudgetStreak = max(0, budgetStreak)
        let normalizedBudgetStreak = min(Double(clampedBudgetStreak) / 6.0, 1.0)
        let budgetStreakComponent = normalizedBudgetStreak * 30.0

        let expenseBase = latestMonthlyActualExpenses ?? 0
        let normalizedCashBufferCoverage: Double
        if expenseBase > 0 {
            normalizedCashBufferCoverage = min(max(cashBuffer, 0) / expenseBase, 1.0)
        } else {
            normalizedCashBufferCoverage = 0
        }
        let cashBufferComponent = normalizedCashBufferCoverage * 30.0

        let rawScore = (savingsComponent + budgetStreakComponent + cashBufferComponent).rounded()
        let clampedScore = min(max(Int(rawScore), 0), 100)

        let status: FinancialHealthStatus
        switch clampedScore {
        case 0...39:
            status = .atRisk
        case 40...69:
            status = .needsAttention
        case 70...89:
            status = .healthy
        default:
            status = .excellent
        }

        return DashboardFinancialHealthDTO(
            score: clampedScore,
            maxScore: 100,
            status: status
        )
    }

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
