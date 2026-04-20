import Foundation
import Fluent
import StockPlanShared

final class ExpenseCategory: Model, @unchecked Sendable {
    static let schema = "expense_categories"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "name")
    var name: String

    @OptionalField(key: "pillar")
    var pillar: String?

    @Field(key: "is_default")
    var isDefault: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, name: String, pillar: BudgetPillar? = nil, isDefault: Bool = false) {
        self.id = id
        self.$user.id = userID
        self.name = name
        self.pillar = pillar?.rawValue
        self.isDefault = isDefault
    }
}
