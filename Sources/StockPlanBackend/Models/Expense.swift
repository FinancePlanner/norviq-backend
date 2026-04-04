import Fluent
import Vapor
import Foundation
import StockPlanShared

final class Expense: Model, @unchecked Sendable {
    static let schema = "expenses"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "title")
    var title: String

    @Field(key: "amount")
    var amount: Double

    @Enum(key: "pillar")
    var pillar: BudgetPillar

    @Field(key: "occurred_on")
    var occurredOn: Date

    @OptionalParent(key: "linked_item_id")
    var linkedPlanItem: BudgetPlanItem?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        title: String,
        amount: Double,
        pillar: BudgetPillar,
        occurredOn: Date,
        linkedPlanItemID: UUID? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.title = title
        self.amount = amount
        self.pillar = pillar
        self.occurredOn = occurredOn
        self.$linkedPlanItem.id = linkedPlanItemID
    }
}
