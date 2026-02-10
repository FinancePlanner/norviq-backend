import Fluent

struct CreateTransaction: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("transactions")
            .id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .cascade))
            .field("instrument_id", .uuid, .required, .references("instruments", "id", onDelete: .cascade))
            .field("external_id", .string)
            .field("type", .string, .required)
            .field("quantity", .double)
            .field("price", .double)
            .field("currency", .string, .required)
            .field("trade_date", .date, .required)
            .field("settle_date", .date)
            .field("fees", .double)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "account_id", "external_id")
            .create()

        try await database.createIndex(on: "transactions", columns: ["account_id", "trade_date"])
        try await database.createIndex(on: "transactions", columns: ["instrument_id", "trade_date"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("transactions").delete()
    }
}
