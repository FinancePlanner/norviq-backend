import Fluent
import Foundation
import StockPlanShared
import Vapor

final class RecurringTemplate: Model, @unchecked Sendable {
    static let schema = "recurring_templates"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "title")
    var title: String

    @Field(key: "amount")
    var amount: Double

    @Field(key: "pillar")
    var pillar: BudgetPillar

    @OptionalParent(key: "category_id")
    var category: ExpenseCategory?

    @Field(key: "frequency")
    var frequency: String

    @Enum(key: "split_mode")
    var splitMode: ExpenseSplitMode

    @Field(key: "user_share_percent")
    var userSharePercent: Double

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        title: String,
        amount: Double,
        pillar: BudgetPillar,
        categoryID: UUID? = nil,
        frequency: RecurringFrequency,
        splitMode: ExpenseSplitMode = .personal,
        userSharePercent: Double = 100
    ) {
        self.id = id
        $user.id = userID
        self.title = title
        self.amount = amount
        self.pillar = pillar
        $category.id = categoryID
        self.frequency = frequency.rawValue
        self.splitMode = splitMode
        self.userSharePercent = userSharePercent
    }
}
