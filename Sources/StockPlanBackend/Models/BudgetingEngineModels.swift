import Fluent
import Foundation
import StockPlanShared

final class BudgetDriftAlertState: Model, @unchecked Sendable {
    static let schema = "budget_drift_alert_states"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Parent(key: "snapshot_id") var snapshot: BudgetSnapshot
    @Field(key: "scope_key") var scopeKey: String
    @Field(key: "level") var level: BudgetDriftLevel
    @Field(key: "breach_sequence") var breachSequence: Int
    @OptionalField(key: "last_notified_level") var lastNotifiedLevel: BudgetDriftLevel?
    @OptionalField(key: "last_notified_at") var lastNotifiedAt: Date?
    @Timestamp(key: "evaluated_at", on: .none) var evaluatedAt: Date?
    @OptionalField(key: "cleared_at") var clearedAt: Date?

    init() {}
}

final class BudgetReallocationEventModel: Model, @unchecked Sendable {
    static let schema = "budget_reallocation_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "request_id") var requestId: UUID
    @Field(key: "source_snapshot_id") var sourceSnapshotId: UUID
    @Field(key: "target_snapshot_id") var targetSnapshotId: UUID
    @Field(key: "effective_month") var effectiveMonth: Date
    @Field(key: "freed_capital") var freedCapital: Double
    @OptionalField(key: "financial_goal_id") var financialGoalId: UUID?
    @OptionalField(key: "portfolio_list_id") var portfolioListId: UUID?
    @Field(key: "adjustments") var adjustments: [BudgetReallocationAdjustment]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

final class BudgetTemplateModel: Model, @unchecked Sendable {
    static let schema = "budget_templates"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "name") var name: String
    @Field(key: "items") var items: [BudgetTemplateItem]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
