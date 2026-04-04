import Fluent
import Vapor
import Foundation
import StockPlanShared

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

    @Enum(key: "pillar")
    var pillar: BudgetPillar

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        snapshotID: UUID,
        userID: UUID,
        title: String,
        plannedAmount: Double,
        pillar: BudgetPillar
    ) {
        self.id = id
        self.$snapshot.id = snapshotID
        self.$user.id = userID
        self.title = title
        self.plannedAmount = plannedAmount
        self.pillar = pillar
    }
}
