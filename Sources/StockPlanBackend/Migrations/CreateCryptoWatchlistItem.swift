import Fluent

struct CreateCryptoWatchlistItem: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("crypto_watchlist_items")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("name", .string, .required)
            .field("note", .string)
            .field("status", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: "crypto_watchlist_items", columns: ["user_id", "symbol"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("crypto_watchlist_items").delete()
    }
}
