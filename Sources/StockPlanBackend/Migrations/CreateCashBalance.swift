import Fluent

struct CreateCashBalance: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("cash_balances")
            .id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .cascade))
            .field("currency", .string, .required)
            .field("balance", .double, .required)
            .field("as_of", .date, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "account_id", "currency", "as_of")
            .create()

        try await database.createIndex(on: "cash_balances", columns: ["account_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("cash_balances").delete()
    }
}
