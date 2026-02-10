import Fluent

struct CreateWatchlistItem: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("watchlist_items")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "symbol")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("watchlist_items").delete()
    }
}
