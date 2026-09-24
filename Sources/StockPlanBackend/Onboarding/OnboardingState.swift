import Fluent
import Foundation
import StockPlanShared
import Vapor

final class OnboardingState: Model, @unchecked Sendable {
    static let schema = "onboarding_state"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @OptionalField(key: "funnel_step")
    var funnelStep: String?

    @OptionalField(key: "funnel_completed_at")
    var funnelCompletedAt: Date?

    @OptionalField(key: "first_holding_at")
    var firstHoldingAt: Date?

    @OptionalField(key: "first_budget_at")
    var firstBudgetAt: Date?

    @OptionalField(key: "first_goal_at")
    var firstGoalAt: Date?

    @OptionalField(key: "guided_start_dismissed_at")
    var guidedStartDismissedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    func toDTO() -> OnboardingStateDTO {
        OnboardingStateDTO(
            funnelStep: funnelStep,
            funnelCompletedAt: funnelCompletedAt,
            addHoldingCompleted: firstHoldingAt != nil,
            firstHoldingAt: firstHoldingAt,
            setBudgetCompleted: firstBudgetAt != nil,
            firstBudgetAt: firstBudgetAt,
            setGoalCompleted: firstGoalAt != nil,
            firstGoalAt: firstGoalAt,
            guidedStartDismissedAt: guidedStartDismissedAt
        )
    }
}
