import Vapor
import Fluent
import Foundation
import StockPlanShared

struct ReportsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let reports = protected.grouped("reports")
        let expenses = reports.grouped("expenses")
        
        reports.get("overview", use: getReportsOverview)
        reports.get("suggestions", use: getSuggestions)
        reports.post("suggestions", ":id", "dismiss", use: dismissSuggestion)
        expenses.get(use: getExpenseReports)
    }

    @Sendable
    func getExpenseReports(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let (fromDate, toDate) = parseDateRange(from: req)
        
        let granularity = req.query[String.self, at: "granularity"] ?? "month"
        
        let res = Response(status: .ok)
        
        if granularity == "year" {
            let reports = try await req.expensesService.getYearlyReports(
                userId: session.userId,
                from: fromDate,
                to: toDate,
                on: req.db
            )
            try res.content.encode(reports)
        } else {
            let reports = try await req.expensesService.getMonthlyReports(
                userId: session.userId,
                from: fromDate,
                to: toDate,
                on: req.db
            )
            try res.content.encode(reports)
        }
        
        return res
    }

    @Sendable
    func getReportsOverview(req: Request) async throws -> ReportsOverviewResponse {
        let session = try req.auth.require(SessionToken.self)
        let (fromDate, toDate) = parseDateRange(from: req)
        let statisticsQuery = StatisticsQueryInput(period: nil, top: nil, benchmark: nil, asOf: nil)

        async let statisticsTask = req.application.statisticsService.overviewStatistics(
            userId: session.userId,
            query: statisticsQuery,
            on: req.db
        )
        async let monthlyReportsTask = req.expensesService.getMonthlyReports(
            userId: session.userId,
            from: fromDate,
            to: toDate,
            on: req.db
        )
        async let yearlyReportsTask = req.expensesService.getYearlyReports(
            userId: session.userId,
            from: fromDate,
            to: toDate,
            on: req.db
        )

        let (statistics, monthlyReports, yearlyReports) = try await (
            statisticsTask,
            monthlyReportsTask,
            yearlyReportsTask
        )

        let latestMonthSummary = monthlyReports.last
        let latestPillarSummaries: [PillarPlanningSummaryResponse]
        if let latestMonthSummary,
           let monthStart = makeDateFormatter().date(from: latestMonthSummary.monthStart) {
            latestPillarSummaries = try await req.expensesService.getPillarPlanningSummaries(
                userId: session.userId,
                monthStart: monthStart,
                on: req.db
            )
        } else {
            latestPillarSummaries = []
        }

        let cashFlow = monthlyReports.map { report in
            let net = report.salary - report.actual
            let savingsRate = report.salary > 0 ? (net / report.salary) * 100 : 0
            return ReportsCashFlowPointResponse(
                monthStart: report.monthStart,
                income: report.salary,
                expenses: report.actual,
                net: net,
                savingsRate: savingsRate
            )
        }

        return ReportsOverviewResponse(
            generatedAt: statistics.generatedAt,
            portfolioStatistics: statistics.importedStocks,
            monthlySummaries: monthlyReports,
            yearlySummaries: yearlyReports,
            latestMonthSummary: latestMonthSummary,
            latestPillarSummaries: latestPillarSummaries,
            cashFlow: cashFlow
        )
    }

    @Sendable
    func getSuggestions(req: Request) async throws -> ReportSuggestionsResponse {
        let session = try req.auth.require(SessionToken.self)
        let (fromDate, toDate) = parseDateRange(from: req)

        async let monthlyReportsTask = req.expensesService.getMonthlyReports(
            userId: session.userId,
            from: fromDate,
            to: toDate,
            on: req.db
        )
        async let planItemsTask = req.expensesService.getAllPlanItems(
            userId: session.userId,
            on: req.db
        )

        let (monthlyReports, planItems) = try await (monthlyReportsTask, planItemsTask)

        let generatedAt = isoTimestamp(Date())
        guard !monthlyReports.isEmpty else {
            return ReportSuggestionsResponse(generatedAt: generatedAt, suggestions: [])
        }

        let suggestions = buildSuggestions(
            monthlyReports: monthlyReports,
            planItems: planItems
        )

        if suggestions.isEmpty {
            return ReportSuggestionsResponse(generatedAt: generatedAt, suggestions: [])
        }

        let suggestionIds = suggestions.map(\.id)
        let dismissed = try await ReportSuggestionDismissal.query(on: req.db)
            .filter(\.$user.$id == session.userId)
            .filter(\.$suggestionId ~~ suggestionIds)
            .all()
        let dismissedIds = Set(dismissed.map(\.suggestionId))

        let visibleSuggestions = suggestions.filter { !dismissedIds.contains($0.id) }
        return ReportSuggestionsResponse(generatedAt: generatedAt, suggestions: visibleSuggestions)
    }

    @Sendable
    func dismissSuggestion(req: Request) async throws -> APISuccess {
        let session = try req.auth.require(SessionToken.self)
        guard let suggestionId = req.parameters.get("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !suggestionId.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid suggestion id.")
        }

        let existing = try await ReportSuggestionDismissal.query(on: req.db)
            .filter(\.$user.$id == session.userId)
            .filter(\.$suggestionId == suggestionId)
            .first()
        if existing == nil {
            let dismissal = ReportSuggestionDismissal(
                userId: session.userId,
                suggestionId: suggestionId,
                dismissedAt: Date()
            )
            try await dismissal.create(on: req.db)
        }

        return APISuccess(success: true)
    }

    private func parseDateRange(from req: Request) -> (Date?, Date?) {
        let dateFormatter = makeDateFormatter()
        let fromDate = req.query[String.self, at: "from"].flatMap { dateFormatter.date(from: $0) }
        let toDate = req.query[String.self, at: "to"].flatMap { dateFormatter.date(from: $0) }
        return (fromDate, toDate)
    }

    private func buildSuggestions(
        monthlyReports: [BudgetMonthSummaryResponse],
        planItems: [BudgetPlanItemResponse]
    ) -> [ReportSuggestionResponse] {
        guard let latest = monthlyReports.last else { return [] }
        var result: [ReportSuggestionResponse] = []

        let monthStart = latest.monthStart
        let planned = max(0, latest.planned)
        let actual = max(0, latest.actual)
        let overspendAmount = max(0, actual - planned)
        let overspendRatio = planned > 0 ? overspendAmount / planned : 0

        if overspendAmount > 0.01 {
            let severity: ReportSuggestionSeverity
            if overspendRatio >= 0.20 {
                severity = .high
            } else if overspendRatio >= 0.10 {
                severity = .medium
            } else {
                severity = .low
            }

            result.append(
                ReportSuggestionResponse(
                    id: "overspend-\(monthStart)-\(Int((overspendRatio * 100).rounded()))",
                    title: "Spending exceeded plan",
                    message: "You spent \(formatPercent(overspendRatio)) above plan in \(monthStart).",
                    severity: severity,
                    category: .overspend,
                    monthStart: monthStart,
                    recommendedSavings: round2(overspendAmount),
                    detailPayload: [
                        "planned": formatAmount(planned),
                        "actual": formatAmount(actual),
                        "overspendAmount": formatAmount(overspendAmount),
                    ]
                )
            )
        }

        let totalUnplanned = latest.pillarActuals.reduce(0.0) { partial, pair in
            let plannedAmount = latest.pillarPlans[pair.key] ?? 0
            return partial + max(0, pair.value - plannedAmount)
        }
        let unplannedRatio = planned > 0 ? totalUnplanned / planned : 0
        if totalUnplanned > 0.01 {
            let severity: ReportSuggestionSeverity
            if unplannedRatio >= 0.20 {
                severity = .high
            } else if unplannedRatio >= 0.10 {
                severity = .medium
            } else {
                severity = .low
            }

            result.append(
                ReportSuggestionResponse(
                    id: "unplanned-\(monthStart)-\(Int(totalUnplanned.rounded()))",
                    title: "High unplanned spend",
                    message: "Unplanned expenses reached \(formatAmount(totalUnplanned)) in \(monthStart).",
                    severity: severity,
                    category: .unplannedSpend,
                    monthStart: monthStart,
                    recommendedSavings: round2(totalUnplanned * 0.5),
                    detailPayload: [
                        "unplannedAmount": formatAmount(totalUnplanned),
                        "unplannedRatio": formatPercent(unplannedRatio),
                        "plannedTotal": formatAmount(planned),
                    ]
                )
            )
        }

        let recent = Array(monthlyReports.suffix(3))
        let savingsRates = recent.map { report in
            guard report.salary > 0 else { return 0.0 }
            let net = report.salary - report.actual
            return (net / report.salary) * 100
        }
        let avgSavingsRate = savingsRates.isEmpty ? 0 : savingsRates.reduce(0, +) / Double(savingsRates.count)
        let isDecliningTrend = savingsRates.count >= 2 && (savingsRates.last ?? 0) < (savingsRates.first ?? 0)
        if avgSavingsRate < 15 || isDecliningTrend {
            let severity: ReportSuggestionSeverity = avgSavingsRate < 5 ? .high : .medium
            let targetRate = 20.0
            let latestSalary = max(0, latest.salary)
            let targetNet = latestSalary * (targetRate / 100)
            let currentNet = latestSalary - actual
            let recommendedSavings = max(0, targetNet - currentNet)

            result.append(
                ReportSuggestionResponse(
                    id: "savings-\(monthStart)-\(Int(avgSavingsRate.rounded()))",
                    title: "Savings trend is weak",
                    message: "Average savings rate over recent months is \(formatPercent(avgSavingsRate / 100)).",
                    severity: severity,
                    category: .savingsTrend,
                    monthStart: monthStart,
                    recommendedSavings: round2(recommendedSavings),
                    detailPayload: [
                        "averageSavingsRate": formatPercent(avgSavingsRate / 100),
                        "latestSavingsRate": formatPercent((savingsRates.last ?? 0) / 100),
                        "monthsEvaluated": String(recent.count),
                        "plannedItemsCount": String(planItems.count),
                    ]
                )
            )
        }

        return result.sorted(by: sortSuggestions)
    }

    private func sortSuggestions(lhs: ReportSuggestionResponse, rhs: ReportSuggestionResponse) -> Bool {
        let leftRank = severityRank(lhs.severity)
        let rightRank = severityRank(rhs.severity)
        if leftRank != rightRank {
            return leftRank > rightRank
        }
        if lhs.recommendedSavings != rhs.recommendedSavings {
            return lhs.recommendedSavings > rhs.recommendedSavings
        }
        return lhs.id < rhs.id
    }

    private func severityRank(_ severity: ReportSuggestionSeverity) -> Int {
        switch severity {
        case .high:
            return 3
        case .medium:
            return 2
        case .low:
            return 1
        }
    }

    private func makeDateFormatter() -> DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        return dateFormatter
    }

    private func formatPercent(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int((value * 100).rounded()))%"
    }

    private func formatAmount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
