import Fluent

struct CreateStock: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("stocks")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("shares", .double, .required)
            .field("buy_price", .double, .required)
            .field("buy_date", .date, .required)
            .field("notes", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: "stocks", columns: ["user_id", "symbol"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("stocks").delete()
    }
}
