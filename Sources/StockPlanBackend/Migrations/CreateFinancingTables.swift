import Fluent

struct CreateFinancingTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FinancingPlan.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("market", .string, .required)
            .field("purchase_type", .string, .required)
            .field("currency", .string, .required)
            .field("status", .string, .required)
            .field("user_share_percent", .double, .required)
            .field("source_domain", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema(FinancingPlanRevision.schema)
            .id()
            .field("plan_id", .uuid, .required, .references(FinancingPlan.schema, "id", onDelete: .cascade))
            .field("effective_installment", .int, .required)
            .field("terms", .json, .required)
            .field("created_at", .datetime)
            .unique(on: "plan_id", "effective_installment")
            .create()

        try await database.schema(FinancingExpenseMatch.schema)
            .id()
            .field("plan_id", .uuid, .required, .references(FinancingPlan.schema, "id", onDelete: .cascade))
            .field("installment_number", .int, .required)
            .field("expense_id", .uuid, .required, .references(Expense.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "plan_id", "installment_number")
            .unique(on: "expense_id")
            .create()

        try await database.schema(FinancingAssumptionsRecord.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("income_scope", .string, .required)
            .field("net_monthly_income_override", .double)
            .field("gross_monthly_income", .double)
            .field("external_monthly_debt_payments", .double, .required)
            .field("safety_buffer_percent", .double, .required)
            .field("monthly_savings_target_override", .double)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(FinancingAssumptionsRecord.schema).delete()
        try await database.schema(FinancingExpenseMatch.schema).delete()
        try await database.schema(FinancingPlanRevision.schema).delete()
        try await database.schema(FinancingPlan.schema).delete()
    }
}
