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

    @Field(key: "currency_code")
    var currencyCode: String

    @Field(key: "category_drift_threshold")
    var categoryDriftThreshold: Double

    @Field(key: "total_drift_threshold")
    var totalDriftThreshold: Double

    @Field(key: "alerts_enabled")
    var alertsEnabled: Bool

    @Field(key: "alert_on_unbudgeted")
    var alertOnUnbudgeted: Bool

    @Field(key: "revision")
    var revision: Int

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
        targetShares: [String: Double],
        currencyCode: String = "USD",
        categoryDriftThreshold: Double = 15,
        totalDriftThreshold: Double = 10,
        alertsEnabled: Bool = true,
        alertOnUnbudgeted: Bool = true,
        revision: Int = 0
    ) {
        self.id = id
        $user.id = userID
        self.monthStart = monthStart
        self.netSalary = netSalary
        self.targetShares = targetShares
        self.currencyCode = currencyCode
        self.categoryDriftThreshold = categoryDriftThreshold
        self.totalDriftThreshold = totalDriftThreshold
        self.alertsEnabled = alertsEnabled
        self.alertOnUnbudgeted = alertOnUnbudgeted
        self.revision = revision
    }
}
