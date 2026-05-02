import Fluent
import Foundation
import Vapor

final class BudgetSnapshot: Model, @unchecked Sendable {
    static let schema = "budget_snapshots"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "month_start")
    var monthStart: Date

    @Field(key: "net_salary")
    var netSalary: Double

    @Field(key: "target_shares")
    var targetShares: [String: Double] // Dictionary mapping pillar names to shares (e.g., ["fundamentals": 0.5])

    @OptionalField(key: "last_budget_alert_threshold")
    var lastBudgetAlertThreshold: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        monthStart: Date,
        netSalary: Double,
        targetShares: [String: Double]
    ) {
        self.id = id
        $user.id = userID
        self.monthStart = monthStart
        self.netSalary = netSalary
        self.targetShares = targetShares
    }
}
