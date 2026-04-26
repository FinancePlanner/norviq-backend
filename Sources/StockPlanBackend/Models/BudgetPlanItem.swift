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
        userSharePercent: Double = 100
    ) {
        self.id = id
        $snapshot.id = snapshotID
        $user.id = userID
        self.title = title
        self.plannedAmount = plannedAmount
        self.pillar = pillar
        self.splitMode = splitMode
        self.userSharePercent = userSharePercent
    }
}
