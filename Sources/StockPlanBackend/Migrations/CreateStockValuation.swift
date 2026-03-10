import Fluent

struct CreateStockValuation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("stock_valuations")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("bear_low", .double, .required)
            .field("bear_high", .double, .required)
            .field("base_low", .double, .required)
            .field("base_high", .double, .required)
            .field("bull_low", .double, .required)
            .field("bull_high", .double, .required)
            .field("rationale", .string)
            .field("target_date", .date)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "symbol")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("stock_valuations").delete()
    }
}
