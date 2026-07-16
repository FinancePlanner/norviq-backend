import Fluent
import Foundation
import StockPlanShared
import Vapor

final class BudgetPlanItem: Model, @unchecked Sendable {
    static let schema = "budget_plan_items"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "snapshot_id")
    var snapshot: BudgetSnapshot

    @Parent(key: "user_id")
    var user: User

    @Field(key: "title")
    var title: String

    @Field(key: "planned_amount")
    var plannedAmount: Double

    @Field(key: "pillar")
    var pillar: BudgetPillar

    @Enum(key: "split_mode")
    var splitMode: ExpenseSplitMode

    @Field(key: "user_share_percent")
    var userSharePercent: Double

    @Field(key: "target_type")
    var targetType: BudgetTargetType

    @OptionalField(key: "income_percentage")
    var incomePercentage: Double?

    @OptionalField(key: "threshold_override")
    var thresholdOverride: Double?

    @Field(key: "allocation_kind")
    var allocationKind: BudgetAllocationKind

    @Field(key: "reallocation_eligible")
    var reallocationEligible: Bool

    @OptionalField(key: "destination_financial_goal_id")
    var destinationFinancialGoalId: UUID?

    @OptionalField(key: "destination_portfolio_list_id")
    var destinationPortfolioListId: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalParent(key: "category_id")
    var category: ExpenseCategory?

    init() {}

    init(
        id: UUID? = nil,
        snapshotID: UUID,
        userID: UUID,
        title: String,
        plannedAmount: Double,
        pillar: BudgetPillar,
        splitMode: ExpenseSplitMode = .personal,
        userSharePercent: Double = 100,
        targetType: BudgetTargetType = .fixed,
        incomePercentage: Double? = nil,
        thresholdOverride: Double? = nil,
        allocationKind: BudgetAllocationKind = .expense,
        reallocationEligible: Bool = false,
        destinationFinancialGoalId: UUID? = nil,
        destinationPortfolioListId: UUID? = nil
    ) {
        self.id = id
        $snapshot.id = snapshotID
        $user.id = userID
        self.title = title
        self.plannedAmount = plannedAmount
        self.pillar = pillar
        self.splitMode = splitMode
        self.userSharePercent = userSharePercent
        self.targetType = targetType
        self.incomePercentage = incomePercentage
        self.thresholdOverride = thresholdOverride
        self.allocationKind = allocationKind
        self.reallocationEligible = reallocationEligible
        self.destinationFinancialGoalId = destinationFinancialGoalId
        self.destinationPortfolioListId = destinationPortfolioListId
    }
}
