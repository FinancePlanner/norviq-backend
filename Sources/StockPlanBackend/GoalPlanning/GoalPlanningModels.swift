import Fluent
import Foundation

final class GoalPortfolioAllocationModel: Model, @unchecked Sendable {
    static let schema = "financial_goal_portfolio_allocations"
    @ID(key: .id) var id: UUID?
    @Parent(key: "goal_id") var goal: FinancialGoalModel
    @Field(key: "user_id") var userId: UUID
    @Field(key: "portfolio_list_id") var portfolioListId: UUID
    @Field(key: "allocation_percentage") var allocationPercentage: Double
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(id: UUID? = nil, goalId: UUID, userId: UUID, portfolioListId: UUID, allocationPercentage: Double) {
        self.id = id; $goal.id = goalId; self.userId = userId
        self.portfolioListId = portfolioListId; self.allocationPercentage = allocationPercentage
    }
}

final class GoalExpenseCategoryLinkModel: Model, @unchecked Sendable {
    static let schema = "financial_goal_expense_category_links"
    @ID(key: .id) var id: UUID?
    @Parent(key: "goal_id") var goal: FinancialGoalModel
    @Field(key: "user_id") var userId: UUID
    @Field(key: "category_id") var categoryId: UUID
    @Field(key: "role") var role: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(id: UUID? = nil, goalId: UUID, userId: UUID, categoryId: UUID, role: String) {
        self.id = id; $goal.id = goalId; self.userId = userId; self.categoryId = categoryId; self.role = role
    }
}

final class GoalContributionModel: Model, @unchecked Sendable {
    static let schema = "financial_goal_contributions"
    @ID(key: .id) var id: UUID?
    @Parent(key: "goal_id") var goal: FinancialGoalModel
    @Field(key: "user_id") var userId: UUID
    @Field(key: "amount") var amount: Double
    @Field(key: "occurred_at") var occurredAt: Date
    @OptionalField(key: "note") var note: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(goalId: UUID, userId: UUID, amount: Double, occurredAt: Date, note: String?) {
        $goal.id = goalId; self.userId = userId; self.amount = amount; self.occurredAt = occurredAt; self.note = note
    }
}

final class GoalProgressSnapshotModel: Model, @unchecked Sendable {
    static let schema = "financial_goal_progress_snapshots"
    @ID(key: .id) var id: UUID?
    @Parent(key: "goal_id") var goal: FinancialGoalModel
    @Field(key: "user_id") var userId: UUID
    @Field(key: "current_value") var currentValue: Double
    @Field(key: "planned_value") var plannedValue: Double
    @Field(key: "projected_value") var projectedValue: Double
    @Field(key: "drift_state") var driftState: String
    @Field(key: "is_month_end") var isMonthEnd: Bool
    @Field(key: "calculated_at") var calculatedAt: Date

    init() {}
    init(goalId: UUID, userId: UUID, currentValue: Double, plannedValue: Double,
         projectedValue: Double, driftState: String, isMonthEnd: Bool, calculatedAt: Date)
    {
        $goal.id = goalId; self.userId = userId; self.currentValue = currentValue
        self.plannedValue = plannedValue; self.projectedValue = projectedValue
        self.driftState = driftState; self.isMonthEnd = isMonthEnd; self.calculatedAt = calculatedAt
    }
}

final class GoalSuggestionModel: Model, @unchecked Sendable {
    static let schema = "financial_goal_suggestions"
    @ID(key: .id) var id: UUID?
    @Parent(key: "goal_id") var goal: FinancialGoalModel
    @Field(key: "user_id") var userId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "title") var title: String
    @Field(key: "explanation") var explanation: String
    @OptionalField(key: "monthly_amount") var monthlyAmount: Double?
    @OptionalField(key: "allocation_percentage") var allocationPercentage: Double?
    @OptionalField(key: "estimated_months_changed") var estimatedMonthsChanged: Int?
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(goalId: UUID, userId: UUID, kind: String, title: String, explanation: String,
         monthlyAmount: Double? = nil, allocationPercentage: Double? = nil,
         estimatedMonthsChanged: Int? = nil, status: String = "proposed")
    {
        $goal.id = goalId; self.userId = userId; self.kind = kind; self.title = title
        self.explanation = explanation; self.monthlyAmount = monthlyAmount
        self.allocationPercentage = allocationPercentage; self.estimatedMonthsChanged = estimatedMonthsChanged
        self.status = status
    }
}

final class GoalAdjustmentDraftModel: Model, @unchecked Sendable {
    static let schema = "financial_goal_adjustment_drafts"
    @ID(key: .id) var id: UUID?
    @Parent(key: "suggestion_id") var suggestion: GoalSuggestionModel
    @Field(key: "user_id") var userId: UUID
    @Field(key: "destination") var destination: String
    @Field(key: "payload") var payload: ScenarioJSON
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(suggestionId: UUID, userId: UUID, destination: String, payload: ScenarioJSON) {
        $suggestion.id = suggestionId; self.userId = userId; self.destination = destination; self.payload = payload
    }
}
