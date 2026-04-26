import Fluent
import StockPlanShared
import Vapor

struct CreateExpensesTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // 1. Budget Snapshots
        try await database.schema(BudgetSnapshot.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("month_start", .date, .required)
            .field("net_salary", .double, .required)
            .field("target_shares", .dictionary, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "month_start")
            .create()

        // 2. Budget Plan Items
        try await database.schema(BudgetPlanItem.schema)
            .id()
            .field("snapshot_id", .uuid, .required, .references(BudgetSnapshot.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("planned_amount", .double, .required)
            .field("pillar", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        // 3. Expenses
        try await database.schema(Expense.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("amount", .double, .required)
            .field("pillar", .string, .required)
            .field("occurred_on", .date, .required)
            .field("linked_item_id", .uuid, .references(BudgetPlanItem.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Expense.schema).delete()
        try await database.schema(BudgetPlanItem.schema).delete()
        try await database.schema(BudgetSnapshot.schema).delete()
    }
}
