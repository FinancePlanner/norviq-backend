import Fluent
import StockPlanShared

struct CreateUserActivity: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let typeEnum = try await database.enum("user_activity_type")
            .case("stock_added")
            .case("expense_recorded")
            .case("stock_updated")
            .case("expense_updated")
            .create()

        try await database.schema("user_activities")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("type", typeEnum, .required)
            .field("title", .string, .required)
            .field("subtitle", .string, .required)
            .field("amount", .double)
            .field("is_growth", .bool, .required)
            .field("symbol", .string, .required)
            .field("created_at", .datetime)
            .create()

        try await database.createIndex(on: "user_activities", columns: ["user_id", "created_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_activities").delete()
        try await database.enum("user_activity_type").delete()
    }
}
