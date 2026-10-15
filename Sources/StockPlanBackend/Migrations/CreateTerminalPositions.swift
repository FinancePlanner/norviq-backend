import Fluent

struct CreateTerminalPositions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("terminal_positions")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("ticker", .string, .required)
            .field("shares_outstanding", .double)
            .field("terminal_share_count", .double, .required)
            .field("terminal_market_cap", .double, .required)
            .field("value_wanted", .double, .required)
            .field("shares_owned", .double, .required)
            .field("current_share_price", .double)
            .field("notes", .string)
            .field("sort_order", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
        try await database.createIndex(on: "terminal_positions", columns: ["user_id", "sort_order"])

        try await database.schema("autobuys")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("ticker", .string)
            .field("label", .string, .required)
            .field("amount", .double, .required)
            .field("cadence", .string, .required)
            .field("percent", .double)
            .field("active", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
        try await database.createIndex(on: "autobuys", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("autobuys").delete()
        try await database.schema("terminal_positions").delete()
    }
}
