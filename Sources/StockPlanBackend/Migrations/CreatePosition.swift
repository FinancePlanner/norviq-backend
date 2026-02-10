import Fluent

struct CreatePosition: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("positions")
            .id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .cascade))
            .field("instrument_id", .uuid, .required, .references("instruments", "id", onDelete: .cascade))
            .field("quantity", .double, .required)
            .field("average_cost", .double, .required)
            .field("currency", .string, .required)
            .field("market_value", .double)
            .field("last_price", .double)
            .field("last_price_date", .date)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "account_id", "instrument_id")
            .create()

        try await database.createIndex(on: "positions", columns: ["account_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("positions").delete()
    }
}
