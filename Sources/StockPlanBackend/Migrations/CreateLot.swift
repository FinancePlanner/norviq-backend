import Fluent

struct CreateLot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("lots")
            .id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .cascade))
            .field("instrument_id", .uuid, .required, .references("instruments", "id", onDelete: .cascade))
            .field("open_transaction_id", .uuid, .references("transactions", "id", onDelete: .setNull))
            .field("close_transaction_id", .uuid, .references("transactions", "id", onDelete: .setNull))
            .field("open_date", .date, .required)
            .field("close_date", .date)
            .field("open_quantity", .double, .required)
            .field("remaining_quantity", .double, .required)
            .field("open_price", .double, .required)
            .field("currency", .string, .required)
            .field("realized_pnl", .double)
            .field("status", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: "lots", columns: ["account_id", "instrument_id"])
        try await database.createIndex(on: "lots", columns: ["status"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("lots").delete()
    }
}
