import Fluent
import Foundation
import StockPlanShared
import Vapor

struct GoalPlanningService {
    private let calendar = Calendar(identifier: .gregorian)

    func goalDTO(_ model: FinancialGoalModel, on db: any Database) async throws -> FinancialGoal {
        guard let id = model.id else { throw Abort(.internalServerError, reason: "Financial goal id missing") }
        let allocations = try await GoalPortfolioAllocationModel.query(on: db)
            .filter(\.$goal.$id == id).sort(\.$createdAt).all()
        let categories = try await GoalExpenseCategoryLinkModel.query(on: db)
            .filter(\.$goal.$id == id).sort(\.$createdAt).all()
        return FinancialGoal(
            id: id.uuidString,
            name: model.name,
            portfolioListId: model.portfolioListId.uuidString,
            goalType: FinancialGoalType(rawValue: model.goalType) ?? .custom,
            targetAmount: model.targetAmount,
            targetDate: Self.dateString(model.targetDate),
            baseCurrency: model.baseCurrency,
            startingCapital: model.startingCapital,
            monthlyContribution: model.monthlyContribution,
            annualContributionGrowth: model.annualContributionGrowth,
            inflationAssumption: model.inflationAssumption,
            riskProfile: FinancialGoalRiskProfile(rawValue: model.riskProfile) ?? .moderate,
            expectedAnnualReturn: model.expectedAnnualReturn,
            status: FinancialGoalStatus(rawValue: model.status) ?? .active,
            portfolioAllocations: allocations.map {
                .init(id: $0.id?.uuidString ?? "", portfolioListId: $0.portfolioListId.uuidString,
                      allocationPercentage: $0.allocationPercentage)
            },
            expenseCategoryLinks: categories.compactMap {
                guard let role = GoalExpenseCategoryRole(rawValue: $0.role) else { return nil }
                return .init(id: $0.id?.uuidString ?? "", categoryId: $0.categoryId.uuidString, role: role)
            },
            createdAt: model.createdAt.map(Self.timestamp),
            updatedAt: model.updatedAt.map(Self.timestamp)
        )
    }

    func progress(
        for goal: FinancialGoalModel,
        userId: UUID,
        monthlyContribution overrideContribution: Double? = nil,
        expectedAnnualReturn overrideReturn: Double? = nil,
        targetDate overrideDate: Date? = nil,
        req: Request
    ) async throws -> GoalProgress {
        guard let goalId = goal.id else { throw Abort(.internalServerError, reason: "Financial goal id missing") }
        let now = Date()
        let targetDate = overrideDate ?? goal.targetDate
        let monthsRemaining = max(0, Self.months(from: now, to: targetDate, calendar: calendar))
        let allocations = try await allocationModels(for: goal, on: req.db)
        let valuation = try await currentValue(
            allocations: allocations,
            fallback: goal.startingCapital,
            userId: userId,
            req: req
        )
        let observed = try await observedMonthlyContribution(goalId: goalId, userId: userId, on: req.db)
        let plannedContribution = overrideContribution ?? goal.monthlyContribution
        let trajectoryContribution = overrideContribution ?? (observed > 0 ? observed : goal.monthlyContribution)
        let annualReturn = overrideReturn ?? goal.expectedAnnualReturn
        let projected = GoalProjectionCalculator.futureValue(
            principal: valuation.value,
            monthlyContribution: trajectoryContribution,
            annualRate: annualReturn,
            months: monthsRemaining
        )
        let monthsElapsed = max(0, Self.months(from: goal.createdAt ?? now, to: now, calendar: calendar))
        let plannedToday = GoalProjectionCalculator.futureValue(
            principal: goal.startingCapital,
            monthlyContribution: goal.monthlyContribution,
            annualRate: goal.expectedAnnualReturn,
            months: monthsElapsed
        )
        let completionMonths = GoalProjectionCalculator.monthsToTarget(
            principal: valuation.value,
            target: goal.targetAmount,
            monthlyContribution: trajectoryContribution,
            annualRate: annualReturn
        )
        let driftMonths = completionMonths.map { $0 - monthsRemaining }
        let state = driftState(
            current: valuation.value,
            target: goal.targetAmount,
            projected: projected,
            driftMonths: driftMonths
        )
        var warnings = valuation.warnings
        if observed == 0, overrideContribution == nil {
            warnings.append("No observed contribution history; projection uses the planned monthly contribution.")
        }
        let snapshots = try await GoalProgressSnapshotModel.query(on: req.db)
            .filter(\.$goal.$id == goalId).sort(\.$calculatedAt).all()
        let trajectory = makeTrajectory(
            goal: goal,
            targetDate: targetDate,
            currentValue: valuation.value,
            monthlyContribution: trajectoryContribution,
            annualReturn: annualReturn,
            snapshots: snapshots,
            now: now
        )
        return GoalProgress(
            goalId: goalId.uuidString,
            currency: goal.baseCurrency,
            currentValue: valuation.value,
            targetAmount: goal.targetAmount,
            percentComplete: min(1, max(0, valuation.value / goal.targetAmount)),
            plannedValueToday: plannedToday,
            projectedValueAtTarget: projected,
            projectedCompletionDate: completionMonths.flatMap { calendar.date(byAdding: .month, value: $0, to: now) }
                .map(Self.dateString),
            driftAmount: projected - goal.targetAmount,
            driftMonths: driftMonths,
            driftState: state,
            plannedMonthlyContribution: plannedContribution,
            observedMonthlyContribution: observed,
            trajectory: trajectory,
            warnings: warnings,
            calculatedAt: Self.timestamp(now)
        )
    }

    func validateLinks(
        _ input: FinancialGoalInput,
        userId: UUID,
        excluding goalId: UUID?,
        on db: any Database
    ) async throws -> [(UUID, Double)] {
        try input.validate()
        let configuredReturn = input.expectedAnnualReturn ?? input.riskProfile.defaultAnnualReturn
        guard abs(configuredReturn - input.riskProfile.defaultAnnualReturn) <= 0.010_001 else {
            throw Abort(.unprocessableEntity, reason: "Expected return must remain within one percentage point of the selected risk profile")
        }
        var allocations: [(UUID, Double)] = []
        var seen = Set<UUID>()
        for allocation in input.portfolioAllocations {
            guard let id = UUID(uuidString: allocation.portfolioListId), seen.insert(id).inserted else {
                throw Abort(.badRequest, reason: "Portfolio allocations must contain unique valid ids")
            }
            guard try await PortfolioList.query(on: db)
                .filter(\.$id == id).filter(\.$userId == userId).first() != nil
            else {
                throw Abort(.notFound, reason: "Portfolio not found")
            }
            try await validateAllocationCapacity(
                portfolioId: id, percentage: allocation.allocationPercentage,
                status: input.status, userId: userId, excluding: goalId, on: db
            )
            allocations.append((id, allocation.allocationPercentage))
        }
        var categoryLinks = Set<String>()
        for link in input.expenseCategoryLinks {
            let key = "\(link.categoryId):\(link.role.rawValue)"
            guard categoryLinks.insert(key).inserted,
                  let id = UUID(uuidString: link.categoryId),
                  try await ExpenseCategory.query(on: db).filter(\.$id == id).filter(\.$user.$id == userId).first() != nil
            else { throw Abort(.badRequest, reason: "Expense category links must be unique and owned by the user") }
        }
        return allocations
    }

    func validateAllocationCapacity(
        portfolioId: UUID,
        percentage: Double,
        status: FinancialGoalStatus,
        userId: UUID,
        excluding goalId: UUID?,
        on db: any Database
    ) async throws {
        guard status == .active else { return }
        let existing = try await GoalPortfolioAllocationModel.query(on: db)
            .filter(\.$portfolioListId == portfolioId).filter(\.$userId == userId).all()
        var used = 0.0
        for row in existing where row.$goal.id != goalId {
            let linkedGoal = try await row.$goal.get(on: db)
            if linkedGoal.status == FinancialGoalStatus.active.rawValue {
                used += row.allocationPercentage
            }
        }
        guard used + percentage <= 100.000_001 else {
            throw Abort(.unprocessableEntity, reason: "Active goal allocations for a portfolio cannot exceed 100%")
        }
    }

    func validateBulkActivation(
        goals: [FinancialGoalModel], userId: UUID, on db: any Database
    ) async throws {
        let selected = Set(goals.compactMap(\.id))
        let active = try await FinancialGoalModel.owned(by: userId, on: db)
            .filter(\.$status == FinancialGoalStatus.active.rawValue).all()
        let included = Set(active.compactMap(\.id)).union(selected)
        let rows = try await GoalPortfolioAllocationModel.query(on: db)
            .filter(\.$userId == userId).all()
        let totals = Dictionary(grouping: rows.filter { included.contains($0.$goal.id) }, by: \.portfolioListId)
            .mapValues { $0.reduce(0) { $0 + $1.allocationPercentage } }
        guard totals.values.allSatisfy({ $0 <= 100.000_001 }) else {
            throw Abort(.unprocessableEntity, reason: "Bulk activation would allocate more than 100% of a portfolio")
        }
    }

    func replaceLinks(
        goalId: UUID,
        userId: UUID,
        input: FinancialGoalInput,
        allocations: [(UUID, Double)],
        on db: any Database
    ) async throws {
        try await GoalPortfolioAllocationModel.query(on: db).filter(\.$goal.$id == goalId).delete()
        try await GoalExpenseCategoryLinkModel.query(on: db).filter(\.$goal.$id == goalId).delete()
        for (portfolioId, percentage) in allocations {
            try await GoalPortfolioAllocationModel(
                goalId: goalId, userId: userId, portfolioListId: portfolioId,
                allocationPercentage: percentage
            ).save(on: db)
        }
        for link in input.expenseCategoryLinks {
            guard let categoryId = UUID(uuidString: link.categoryId) else { continue }
            try await GoalExpenseCategoryLinkModel(
                goalId: goalId, userId: userId, categoryId: categoryId, role: link.role.rawValue
            ).save(on: db)
        }
    }

    func suggestions(for goal: FinancialGoalModel, userId: UUID, req: Request) async throws -> [GoalSuggestion] {
        guard let goalId = goal.id else { throw Abort(.internalServerError) }
        let progress = try await progress(for: goal, userId: userId, req: req)
        let refreshCutoff = Date().addingTimeInterval(-86400)
        let stale = try await GoalSuggestionModel.query(on: req.db)
            .filter(\.$goal.$id == goalId).filter(\.$status == GoalSuggestionStatus.proposed.rawValue)
            .filter(\.$createdAt < refreshCutoff).all()
        for item in stale {
            try await item.delete(on: req.db)
        }
        let existing = try await GoalSuggestionModel.query(on: req.db)
            .filter(\.$goal.$id == goalId).filter(\.$status == GoalSuggestionStatus.proposed.rawValue)
            .sort(\.$createdAt, .descending).all()
        if !existing.isEmpty {
            return existing.map(Self.suggestionDTO)
        }

        var generated: [GoalSuggestionModel] = []
        if progress.driftState == .behind {
            let months = max(1, Self.months(from: Date(), to: goal.targetDate, calendar: calendar))
            let required = try GoalProjectionCalculator.requiredMonthlyContribution(
                principal: progress.currentValue,
                target: goal.targetAmount,
                annualRate: goal.expectedAnnualReturn,
                months: months
            )
            let increase = max(0, required - progress.observedMonthlyContribution)
            if increase > 0.5 {
                generated.append(.init(
                    goalId: goalId, userId: userId, kind: GoalSuggestionKind.increaseContribution.rawValue,
                    title: "Increase monthly contributions",
                    explanation: "Adding \(Self.money(increase, currency: goal.baseCurrency)) per month closes the projected shortfall at the current return assumption.",
                    monthlyAmount: increase,
                    estimatedMonthsChanged: progress.driftMonths.map { -max(0, $0) }
                ))
            }
            if let reduction = try await reductionCandidate(goalId: goalId, userId: userId, on: req.db), reduction > 0 {
                generated.append(.init(
                    goalId: goalId, userId: userId, kind: GoalSuggestionKind.reduceSpending.rawValue,
                    title: "Redirect flexible spending",
                    explanation: "Redirecting up to \(Self.money(reduction, currency: goal.baseCurrency)) per month from linked categories can fund this goal. Review the budget draft before applying it.",
                    monthlyAmount: reduction
                ))
            }
            if try await supportsAllocationAdvice(goal: goal, userId: userId, on: req.db) {
                generated.append(.init(
                    goalId: goalId, userId: userId, kind: GoalSuggestionKind.rebalanceAllocation.rawValue,
                    title: "Review allocation within your risk band",
                    explanation: "A scenario up to one percentage point above the \(goal.riskProfile) return assumption remains inside the configured guardrail. Review a rebalance draft before applying trades.",
                    allocationPercentage: 1
                ))
            }
            generated.append(.init(
                goalId: goalId, userId: userId, kind: GoalSuggestionKind.extendTargetDate.rawValue,
                title: "Consider a later target date",
                explanation: "Extending the target by \(max(1, progress.driftMonths ?? 1)) months preserves the current contribution trajectory.",
                estimatedMonthsChanged: progress.driftMonths
            ))
        } else if progress.driftState == .ahead, goal.monthlyContribution > 0 {
            let months = max(1, Self.months(from: Date(), to: goal.targetDate, calendar: calendar))
            let required = try GoalProjectionCalculator.requiredMonthlyContribution(
                principal: progress.currentValue, target: goal.targetAmount,
                annualRate: goal.expectedAnnualReturn, months: months
            )
            let reduction = max(0, goal.monthlyContribution - required)
            if reduction > 0.5 {
                generated.append(.init(
                    goalId: goalId, userId: userId, kind: GoalSuggestionKind.reduceContribution.rawValue,
                    title: "You have contribution headroom",
                    explanation: "You could reduce monthly contributions by \(Self.money(reduction, currency: goal.baseCurrency)) and remain on plan under current assumptions.",
                    monthlyAmount: reduction
                ))
            }
        }
        for item in generated {
            try await item.save(on: req.db)
        }
        return generated.map(Self.suggestionDTO)
    }

    func persistSnapshot(_ progress: GoalProgress, goal: FinancialGoalModel, userId: UUID, on db: any Database) async throws {
        guard let goalId = goal.id else { return }
        let now = Date()
        let components = calendar.dateComponents([.day, .month, .year], from: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let isMonthEnd = calendar.component(.month, from: tomorrow) != components.month
        try await GoalProgressSnapshotModel(
            goalId: goalId, userId: userId, currentValue: progress.currentValue,
            plannedValue: progress.plannedValueToday, projectedValue: progress.projectedValueAtTarget,
            driftState: progress.driftState.rawValue, isMonthEnd: isMonthEnd, calculatedAt: now
        ).save(on: db)
    }

    private func allocationModels(for goal: FinancialGoalModel, on db: any Database) async throws -> [GoalPortfolioAllocationModel] {
        guard let goalId = goal.id else { return [] }
        let rows = try await GoalPortfolioAllocationModel.query(on: db).filter(\.$goal.$id == goalId).all()
        return rows.isEmpty ? [GoalPortfolioAllocationModel(
            goalId: goalId, userId: goal.userId, portfolioListId: goal.portfolioListId,
            allocationPercentage: 100
        )] : rows
    }

    private func currentValue(
        allocations: [GoalPortfolioAllocationModel], fallback: Double, userId: UUID, req: Request
    ) async throws -> (value: Double, warnings: [String]) {
        guard !allocations.isEmpty else { return (fallback, []) }
        var total = 0.0
        var warnings: [String] = []
        for allocation in allocations {
            let holdings = try await Stock.query(on: req.db)
                .filter(\.$userId == userId).filter(\.$portfolioListId == allocation.portfolioListId).all()
            var portfolioValue = 0.0
            for holding in holdings {
                let quote = try? await req.application.marketDataService.quote(symbol: holding.symbol, on: req)
                if quote == nil {
                    warnings.append("Live price unavailable for \(holding.symbol); purchase price used.")
                }
                portfolioValue += holding.shares * (quote?.currentPrice ?? holding.buyPrice)
            }
            total += portfolioValue * allocation.allocationPercentage / 100
        }
        if total == 0, fallback > 0 {
            warnings.append("Linked portfolios have no valued holdings; starting capital is used.")
            return (fallback, warnings)
        }
        return (total, Array(Set(warnings)).sorted())
    }

    private func observedMonthlyContribution(goalId: UUID, userId: UUID, on db: any Database) async throws -> Double {
        let start = calendar.date(byAdding: .month, value: -3, to: Date()) ?? .distantPast
        let manual = try await GoalContributionModel.query(on: db)
            .filter(\.$goal.$id == goalId).filter(\.$userId == userId)
            .filter(\.$occurredAt >= start).all().reduce(0) { $0 + $1.amount }
        let categoryIds = try await GoalExpenseCategoryLinkModel.query(on: db)
            .filter(\.$goal.$id == goalId).filter(\.$role == GoalExpenseCategoryRole.observedContribution.rawValue)
            .all().map(\.categoryId)
        guard !categoryIds.isEmpty else { return manual / 3 }
        let expenses = try await Expense.query(on: db)
            .filter(\.$user.$id == userId).filter(\.$occurredOn >= start)
            .filter(\.$category.$id ~~ categoryIds).all()
        return (manual + expenses.reduce(0) { $0 + $1.amount }) / 3
    }

    private func reductionCandidate(goalId: UUID, userId: UUID, on db: any Database) async throws -> Double? {
        let categoryIds = try await GoalExpenseCategoryLinkModel.query(on: db)
            .filter(\.$goal.$id == goalId).filter(\.$role == GoalExpenseCategoryRole.reductionCandidate.rawValue)
            .all().map(\.categoryId)
        guard !categoryIds.isEmpty else { return nil }
        let start = calendar.date(byAdding: .month, value: -3, to: Date()) ?? .distantPast
        let expenses = try await Expense.query(on: db).filter(\.$user.$id == userId)
            .filter(\.$occurredOn >= start).filter(\.$category.$id ~~ categoryIds).all()
        return expenses.reduce(0) { $0 + $1.amount } / 3 * 0.2
    }

    private func supportsAllocationAdvice(goal: FinancialGoalModel, userId: UUID, on db: any Database) async throws -> Bool {
        guard goal.riskProfile != FinancialGoalRiskProfile.conservative.rawValue else { return false }
        let allocations = try await allocationModels(for: goal, on: db)
        let portfolioIds = allocations.map(\.portfolioListId)
        guard !portfolioIds.isEmpty else { return false }
        let holdings = try await Stock.query(on: db).filter(\.$userId == userId)
            .filter(\.$portfolioListId ~~ portfolioIds).all()
        let supported = Set(["stock", "etf", "mutual_fund", "cash", "bond"])
        return !holdings.isEmpty && holdings.allSatisfy { supported.contains($0.category.rawValue) }
    }

    private func makeTrajectory(
        goal: FinancialGoalModel, targetDate: Date, currentValue: Double, monthlyContribution: Double,
        annualReturn: Double, snapshots: [GoalProgressSnapshotModel], now: Date
    ) -> [GoalTrajectoryPoint] {
        let start = goal.createdAt ?? now
        let totalMonths = max(1, Self.months(from: start, to: targetDate, calendar: calendar))
        let elapsed = max(0, Self.months(from: start, to: now, calendar: calendar))
        let snapshotByMonth = Dictionary(grouping: snapshots) { Self.monthKey($0.calculatedAt) }
            .compactMapValues { $0.last }
        return (0 ... totalMonths).map { month in
            let date = calendar.date(byAdding: .month, value: month, to: start) ?? start
            let planned = GoalProjectionCalculator.futureValue(
                principal: goal.startingCapital, monthlyContribution: goal.monthlyContribution,
                annualRate: goal.expectedAnnualReturn, months: month
            )
            let futureMonth = max(0, month - elapsed)
            let projected = month < elapsed ? planned : GoalProjectionCalculator.futureValue(
                principal: currentValue, monthlyContribution: monthlyContribution,
                annualRate: annualReturn, months: futureMonth
            )
            return GoalTrajectoryPoint(
                date: Self.dateString(date), plannedValue: planned,
                actualValue: snapshotByMonth[Self.monthKey(date)]?.currentValue,
                projectedValue: projected
            )
        }
    }

    private func driftState(current: Double, target: Double, projected: Double, driftMonths: Int?) -> GoalDriftState {
        if current >= target {
            return .complete
        }
        guard let driftMonths else { return .insufficientData }
        if abs(projected - target) <= target * 0.01 || abs(driftMonths) <= 1 {
            return .onTrack
        }
        return driftMonths < 0 ? .ahead : .behind
    }

    private static func suggestionDTO(_ model: GoalSuggestionModel) -> GoalSuggestion {
        GoalSuggestion(
            id: model.id?.uuidString ?? "", goalId: model.$goal.id.uuidString,
            kind: GoalSuggestionKind(rawValue: model.kind) ?? .increaseContribution,
            title: model.title, explanation: model.explanation, monthlyAmount: model.monthlyAmount,
            allocationPercentage: model.allocationPercentage, estimatedMonthsChanged: model.estimatedMonthsChanged,
            status: GoalSuggestionStatus(rawValue: model.status) ?? .proposed,
            createdAt: timestamp(model.createdAt ?? Date())
        )
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date
        }
        let day = DateFormatter(); day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        return day.date(from: value)
    }

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func monthKey(_ date: Date) -> String {
        String(dateString(date).prefix(7))
    }

    private static func months(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.month], from: start, to: end).month ?? 0
    }

    private static func money(_ value: Double, currency: String) -> String {
        "\(currency.uppercased()) \(String(format: "%.0f", value))"
    }
}
