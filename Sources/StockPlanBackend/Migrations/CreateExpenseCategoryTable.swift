import Fluent
import StockPlanShared

struct CreateExpenseCategoryTable: AsyncMigration {
    private static let defaults: [(name: String, pillar: BudgetPillar)] = [
        ("Groceries", .fundamentals), ("Rent", .fundamentals), ("Mortgage", .fundamentals),
        ("Utilities", .fundamentals), ("Transport", .fundamentals), ("Insurance", .fundamentals),
        ("Phone Bill", .fundamentals),
        ("Savings", .futureYou), ("Investments", .futureYou), ("Emergency Fund", .futureYou),
        ("Dining Out", .fun), ("Entertainment", .fun), ("Travel", .fun), ("Subscriptions", .fun),
    ]

    func prepare(on database: any Database) async throws {
        try await database.schema(ExpenseCategory.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("pillar", .string)
            .field("is_default", .bool, .required)
            .field("created_at", .datetime)
            .create()

        try await database.schema(Expense.schema)
            .field("category_id", .uuid, .references(ExpenseCategory.schema, "id", onDelete: .setNull))
            .update()

        try await database.schema(BudgetPlanItem.schema)
            .field("category_id", .uuid, .references(ExpenseCategory.schema, "id", onDelete: .setNull))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BudgetPlanItem.schema).deleteField("category_id").update()
        try await database.schema(Expense.schema).deleteField("category_id").update()
        try await database.schema(ExpenseCategory.schema).delete()
    }
}
