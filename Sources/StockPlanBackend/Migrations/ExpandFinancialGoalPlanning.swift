import Fluent
import FluentSQL

struct ExpandFinancialGoalPlanning: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FinancialGoalModel.schema)
            .field("goal_type", .string, .required, .sql(.default(SQLRaw("'custom'"))))
            .field("starting_capital", .double, .required, .sql(.default(SQLRaw("0"))))
            .field("risk_profile", .string, .required, .sql(.default(SQLRaw("'moderate'"))))
            .field("expected_annual_return", .double, .required, .sql(.default(SQLRaw("0.06"))))
            .field("status", .string, .required, .sql(.default(SQLRaw("'active'"))))
            .update()

        try await database.schema(GoalPortfolioAllocationModel.schema)
            .id().field("goal_id", .uuid, .required, .references(FinancialGoalModel.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("portfolio_list_id", .uuid, .required, .references(PortfolioList.schema, "id", onDelete: .cascade))
            .field("allocation_percentage", .double, .required).field("created_at", .datetime)
            .unique(on: "goal_id", "portfolio_list_id").create()
        try await database.schema(GoalExpenseCategoryLinkModel.schema)
            .id().field("goal_id", .uuid, .required, .references(FinancialGoalModel.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("category_id", .uuid, .required, .references(ExpenseCategory.schema, "id", onDelete: .cascade))
            .field("role", .string, .required).field("created_at", .datetime)
            .unique(on: "goal_id", "category_id", "role").create()
        try await database.schema(GoalContributionModel.schema)
            .id().field("goal_id", .uuid, .required, .references(FinancialGoalModel.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("amount", .double, .required).field("occurred_at", .datetime, .required)
            .field("note", .string).field("created_at", .datetime).create()
        try await database.schema(GoalProgressSnapshotModel.schema)
            .id().field("goal_id", .uuid, .required, .references(FinancialGoalModel.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("current_value", .double, .required).field("planned_value", .double, .required)
            .field("projected_value", .double, .required).field("drift_state", .string, .required)
            .field("is_month_end", .bool, .required).field("calculated_at", .datetime, .required).create()
        try await database.schema(GoalSuggestionModel.schema)
            .id().field("goal_id", .uuid, .required, .references(FinancialGoalModel.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required).field("title", .string, .required)
            .field("explanation", .string, .required).field("monthly_amount", .double)
            .field("allocation_percentage", .double).field("estimated_months_changed", .int)
            .field("status", .string, .required).field("created_at", .datetime).create()
        try await database.schema(GoalAdjustmentDraftModel.schema)
            .id().field("suggestion_id", .uuid, .required, .references(GoalSuggestionModel.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("destination", .string, .required).field("payload", .json, .required)
            .field("created_at", .datetime).create()

        let goals = try await FinancialGoalModel.query(on: database).all()
        for goal in goals {
            guard let goalId = goal.id else { continue }
            try await GoalPortfolioAllocationModel(
                goalId: goalId, userId: goal.userId, portfolioListId: goal.portfolioListId,
                allocationPercentage: 100
            ).save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(GoalAdjustmentDraftModel.schema).delete()
        try await database.schema(GoalSuggestionModel.schema).delete()
        try await database.schema(GoalProgressSnapshotModel.schema).delete()
        try await database.schema(GoalContributionModel.schema).delete()
        try await database.schema(GoalExpenseCategoryLinkModel.schema).delete()
        try await database.schema(GoalPortfolioAllocationModel.schema).delete()
        try await database.schema(FinancialGoalModel.schema)
            .deleteField("goal_type").deleteField("starting_capital").deleteField("risk_profile")
            .deleteField("expected_annual_return").deleteField("status").update()
    }
}
